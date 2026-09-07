import std/[sets, strutils]

import ../index/source_index
import ../index/symbols
import ../session/workspace
import ../stdlib/map
import ../syntax/imports
import ../syntax/lexer
import ./definition

type
  SignatureState* = enum
    signatureUnavailable
    signatureAvailable

  SignatureCandidate* = object
    label*: string
    parameters*: seq[string]

  SignatureHelpInfo* = object
    state*: SignatureState
    activeParameter*: int
    signatures*: seq[SignatureCandidate]

  CallContext = object
    calleeToken: int
    qualifierToken: int
    activeParameter: int

proc tokenIs(tokens: TokenStore, index: int, wanted: string): bool {.inline.} =
  index >= 0 and index < tokens.len and tokens.tokenTextEquals(tokens[index], wanted)

proc sourceSpan(source: string, tokens: TokenStore, first, past: int): string =
  if first < 0 or past <= first or past > tokens.len:
    return
  let start = tokens[first].startOffset
  let finish = tokens[past - 1].endOffset
  if start < 0 or finish <= start or finish > source.len:
    return
  source[start ..< finish].strip

proc callContext(
    tokens: TokenStore, byteOffset: int
): tuple[valid: bool, value: CallContext] =
  var cursor = -1
  for index, token in tokens:
    if token.startOffset > byteOffset:
      break
    cursor = index
  if cursor < 0:
    return

  var depth = 0
  var opening = -1
  for index in countdown(cursor, 0):
    if tokenIs(tokens, index, ")") or tokenIs(tokens, index, "]") or
        tokenIs(tokens, index, "}"):
      inc depth
    elif tokenIs(tokens, index, "(") or tokenIs(tokens, index, "[") or
        tokenIs(tokens, index, "{"):
      if depth > 0:
        dec depth
      elif tokenIs(tokens, index, "("):
        opening = index
        break
      else:
        return
  if opening <= 0 or tokens[opening - 1].kind != tkIdentifier:
    return

  result.value.calleeToken = opening - 1
  result.value.qualifierToken = -1
  if opening >= 3 and tokenIs(tokens, opening - 2, ".") and
      tokens[opening - 3].kind == tkIdentifier:
    result.value.qualifierToken = opening - 3

  depth = 0
  for index in opening + 1 ..< min(tokens.len, cursor + 1):
    if tokenIs(tokens, index, "(") or tokenIs(tokens, index, "[") or
        tokenIs(tokens, index, "{"):
      inc depth
    elif tokenIs(tokens, index, ")") or tokenIs(tokens, index, "]") or
        tokenIs(tokens, index, "}"):
      if depth > 0:
        dec depth
    elif depth == 0 and tokenIs(tokens, index, ","):
      inc result.value.activeParameter
  result.valid = true

proc matchingCallClose(tokens: TokenStore, opening: int): int =
  var delimiters: seq[char] = @[]
  for index in opening ..< tokens.len:
    let token = tokens[index]
    if token.kind != tkPunctuation or tokens.tokenTextLen(token) != 1:
      continue
    let value = tokens.tokenTextChar(token, 0)
    if isOpeningDelimiter(value):
      delimiters.add value
    elif isClosingDelimiter(value):
      if delimiters.len == 0 or not matchingDelimiter(delimiters[^1], value):
        return -1
      delimiters.setLen(delimiters.len - 1)
      if delimiters.len == 0:
        return index
  -1

proc sourceSignature(
    source: WorkspaceSnapshot, symbol: SourceSymbol
): SignatureCandidate =
  if not source.valid or source.index == nil or
      symbol.nameToken >= uint32(source.index.parsed.tokens.len) or
      symbol.kind notin {
        symbolProc, symbolFunc, symbolIterator, symbolMethod, symbolMacro,
        symbolTemplate, symbolConverter,
      }:
    return
  let tokens = source.index.parsed.tokens
  let name = int(symbol.nameToken)
  var opening = -1
  var routine = name - 1
  while routine >= 0 and tokens[routine].line == tokens[name].line:
    if tokens[routine].hasKeywordRole(roleRoutine):
      break
    dec routine
  if routine < 0 or not tokens[routine].hasKeywordRole(roleRoutine):
    return
  for index in name + 1 ..< tokens.len:
    if tokens[index].line > tokens[name].line and tokens[index].column == 0:
      break
    if tokenIs(tokens, index, "("):
      opening = index
      break
  if opening < 0:
    return
  let closing = matchingCallClose(tokens, opening)
  if closing < 0:
    return

  var segment = opening + 1
  var depth = 0
  for index in opening + 1 ..< closing:
    if tokenIs(tokens, index, "(") or tokenIs(tokens, index, "[") or
        tokenIs(tokens, index, "{"):
      inc depth
    elif tokenIs(tokens, index, ")") or tokenIs(tokens, index, "]") or
        tokenIs(tokens, index, "}"):
      if depth > 0:
        dec depth
    elif depth == 0 and tokenIs(tokens, index, ","):
      let parameter = sourceSpan(source.text, tokens, segment, index)
      if parameter.len > 0:
        result.parameters.add parameter
      segment = index + 1
  let parameter = sourceSpan(source.text, tokens, segment, closing)
  if parameter.len > 0:
    result.parameters.add parameter

  var finish = closing + 1
  while finish < tokens.len and tokens[finish].line == tokens[closing].line and
      not tokenIs(tokens, finish, "="):
    inc finish
  result.label = sourceSpan(source.text, tokens, routine, finish)

proc addCandidate(
    candidates: var seq[SignatureCandidate], candidate: SignatureCandidate
) =
  if candidate.label.len == 0:
    return
  for existing in candidates:
    if existing.label == candidate.label:
      return
  candidates.add candidate

proc projectSignature(
    workspace: Workspace, source: WorkspaceSnapshot, context: CallContext
): SignatureCandidate =
  let tokens = source.index.parsed.tokens
  let localSymbol = source.index.symbols.lookupSymbol(
    tokens, tokens.tokenText(tokens[context.calleeToken])
  )
  if localSymbol >= 0 and
      source.index.symbols[localSymbol].nameToken < uint32(context.calleeToken):
    return sourceSignature(source, source.index.symbols[localSymbol])
  let resolution = resolveDefinitionAtToken(workspace, source, context.calleeToken)
  if resolution.kind != definitionResolved or resolution.target.kind != targetDeclaration:
    return
  var target = source
  if uint32(resolution.target.fileId) != uint32(source.fileId):
    target = workspace.snapshotForFile(resolution.target.fileId)
  if not target.valid or target.index == nil or
      uint64(target.contentGeneration) != uint64(resolution.target.contentGeneration):
    return
  let symbolIndex = target.index.symbols.symbolToken(resolution.target.nameToken)
  if symbolIndex >= 0:
    result = sourceSignature(target, target.index.symbols[symbolIndex])

proc stdlibSignatures(
    source: WorkspaceSnapshot, stdlib: StdlibMap, context: CallContext
): seq[SignatureCandidate] =
  if stdlib == nil or not source.valid or source.index == nil:
    return
  let tokens = source.index.parsed.tokens
  let name = tokens.tokenText(tokens[context.calleeToken])
  var qualifier = ""
  if context.qualifierToken >= 0:
    qualifier = tokens.tokenText(tokens[context.qualifierToken])
  for item in source.index.parsed.imports:
    if item.synthetic or item.conditional or item.excluded.len > 0:
      continue
    var matchesImport = false
    if qualifier.len > 0:
      matchesImport =
        item.form == importModule and (
          (item.alias.len > 0 and sameIdentifier(item.alias, qualifier)) or
          (item.alias.len == 0 and sameIdentifier(moduleLeaf(item.module), qualifier))
        )
    elif item.form == fromModule:
      for imported in item.importedSymbols:
        if sameIdentifier(imported.name, name):
          matchesImport = true
          break
    else:
      matchesImport = item.form == importModule and item.alias.len == 0
    if not matchesImport:
      continue
    for candidate in stdlib.candidatesFor(name, qualifier):
      if sameModule(candidate.module, item.module):
        result.addCandidate SignatureCandidate(
          label: candidate.signature, parameters: @[]
        )

proc resolveSignatureHelp*(
    workspace: Workspace, source: WorkspaceSnapshot, byteOffset: int, stdlib: StdlibMap
): SignatureHelpInfo =
  if workspace == nil or not source.valid or source.index == nil:
    return
  let context = callContext(source.index.parsed.tokens, byteOffset)
  if not context.valid:
    return
  result.activeParameter = context.value.activeParameter
  let project = workspace.projectSignature(source, context.value)
  if project.label.len > 0:
    result.signatures.addCandidate project
  else:
    result.signatures = stdlibSignatures(source, stdlib, context.value)
  if result.signatures.len > 0:
    result.state = signatureAvailable
