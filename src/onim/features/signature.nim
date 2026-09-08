import std/[sets, strutils]

import ../index/source_index
import ../index/symbols
import ../session/ids
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

  FromImportBindingKind = enum
    fromImportNone
    fromImportPlain
    fromImportAlias
    fromImportUnsupported

  FromImportBinding = object
    kind: FromImportBindingKind
    providerName: string

  FromImportFallback = enum
    fromFallbackAllowed
    fromFallbackBlocked

  FromProjectSignatures = object
    fallback: FromImportFallback
    signatures: seq[SignatureCandidate]

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

proc signatureParameters(
    source: string, tokens: TokenStore, opening, closing: int
): seq[string] =
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
    elif depth == 0 and (tokenIs(tokens, index, ",") or tokenIs(tokens, index, ";")):
      let parameter = sourceSpan(source, tokens, segment, index)
      if parameter.len > 0:
        result.add parameter
      segment = index + 1
  let parameter = sourceSpan(source, tokens, segment, closing)
  if parameter.len > 0:
    result.add parameter

proc signatureParameters(signature: string): seq[string] =
  let tokens = lex(signature)
  var opening = -1
  for index, token in tokens:
    if tokenIs(tokens, index, "("):
      opening = index
      break
  if opening >= 0:
    let closing = matchingCallClose(tokens, opening)
    if closing >= 0:
      result = signatureParameters(signature, tokens, opening, closing)

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

  result.parameters = signatureParameters(source.text, tokens, opening, closing)

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

proc sameFileOverloadSignatures(
    source: WorkspaceSnapshot, context: CallContext
): seq[SignatureCandidate] =
  if not source.valid or source.index == nil or context.qualifierToken >= 0 or
      context.calleeToken < 0 or context.calleeToken >= source.index.parsed.tokens.len:
    return
  if resolveLocalDefinitionAtToken(source, context.calleeToken).kind != definitionUnknown:
    return
  let tokens = source.index.parsed.tokens
  let wanted = identifierKey(tokens, tokens[context.calleeToken])
  if wanted.len == 0:
    return
  var matches = 0
  for symbol in source.index.symbols:
    if symbol.nameToken >= uint32(context.calleeToken) or not symbol.kind.routineKind or
        symbol.nameToken >= uint32(tokens.len):
      continue
    if identifierKey(tokens, tokens[int(symbol.nameToken)]) == wanted:
      inc matches
  if matches < 2:
    return
  for symbol in source.index.symbols:
    if symbol.nameToken >= uint32(context.calleeToken) or not symbol.kind.routineKind or
        symbol.nameToken >= uint32(tokens.len):
      continue
    if identifierKey(tokens, tokens[int(symbol.nameToken)]) == wanted:
      result.addCandidate sourceSignature(source, symbol)

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

proc importQualifierMatches(item: ImportInfo, qualifier: string): bool {.inline.} =
  item.form == importModule and (
    (item.alias.len > 0 and sameIdentifier(item.alias, qualifier)) or
    (item.alias.len == 0 and sameIdentifier(moduleLeaf(item.module), qualifier))
  )

proc projectOverloadSignatures(
    target: WorkspaceSnapshot, snapshotId: SnapshotId, name: string
): seq[SignatureCandidate] =
  if not target.valid or target.id.value != snapshotId.value or target.index == nil or
      not target.index.nativeIndexSafe():
    return
  for symbol in target.index.symbols:
    if not symbol.exported or not symbol.kind.routineKind or
        symbol.nameToken >= uint32(target.index.parsed.tokens.len):
      continue
    if sameIdentifier(
      target.index.parsed.tokens.tokenText(
        target.index.parsed.tokens[int(symbol.nameToken)]
      ),
      name,
    ):
      result.addCandidate target.sourceSignature(symbol)

proc qualifiedProjectOverloadSignatures(
    workspace: Workspace, source: WorkspaceSnapshot, context: CallContext
): seq[SignatureCandidate] =
  if workspace == nil or not source.valid or source.index == nil or
      context.qualifierToken < 0 or context.calleeToken < 0 or
      context.calleeToken >= source.index.parsed.tokens.len:
    return
  let tokens = source.index.parsed.tokens
  let qualifier = tokens.tokenText(tokens[context.qualifierToken])
  let name = tokens.tokenText(tokens[context.calleeToken])
  var matches = 0
  for item in source.index.parsed.imports:
    if item.synthetic or item.conditional or item.excluded.len > 0 or
        not item.importQualifierMatches(qualifier) or item.module.startsWith("std/"):
      continue
    if matches > 0:
      return
    inc matches
    let moduleId = workspace.resolveModule(source.fileId, item.module)
    if not moduleId.valid:
      return
    let target = workspace.snapshotForFile(moduleId)
    result = target.projectOverloadSignatures(source.id, name)

proc fromImportHasExcept(source: WorkspaceSnapshot, item: ImportInfo): bool {.inline.} =
  for token in source.index.parsed.tokens:
    if token.startOffset < item.startOffset or token.endOffset > item.endOffset:
      continue
    if token.isKeyword(kwExcept):
      return true

proc fromImportBinding(
    source: WorkspaceSnapshot, item: ImportInfo, name: string
): FromImportBinding =
  if item.form != fromModule:
    return
  for imported in item.importedSymbols:
    if not sameIdentifier(imported.name, name):
      continue
    result.kind = fromImportUnsupported
    if item.synthetic or item.conditional or item.excluded.len > 0 or
        source.fromImportHasExcept(item):
      return
    if imported.startOffset < 0 or imported.endOffset <= imported.startOffset or
        imported.endOffset > source.text.len:
      return
    var firstToken = -1
    var tokenCount = 0
    for tokenIndex, token in source.index.parsed.tokens:
      if token.startOffset < imported.startOffset or token.endOffset > imported.endOffset:
        continue
      if firstToken < 0:
        firstToken = tokenIndex
      inc tokenCount
    if tokenCount == 1:
      result.kind = fromImportPlain
      result.providerName =
        source.text[imported.startOffset ..< imported.endOffset].strip(chars = {'`'})
    elif tokenCount == 3 and firstToken >= 0:
      let tokens = source.index.parsed.tokens
      let original = tokens[firstToken]
      let asToken = tokens[firstToken + 1]
      let alias = tokens[firstToken + 2]
      if original.kind == tkIdentifier and asToken.isKeyword(kwAs) and
          alias.kind == tkIdentifier:
        result.kind = fromImportAlias
        result.providerName = tokens.tokenText(original)
    return

proc fromProjectOverloadSignatures(
    workspace: Workspace, source: WorkspaceSnapshot, context: CallContext
): FromProjectSignatures =
  if workspace == nil or not source.valid or source.index == nil or
      context.qualifierToken >= 0 or context.calleeToken < 0 or
      context.calleeToken >= source.index.parsed.tokens.len:
    return
  let name = source.index.parsed.tokens.tokenText(
    source.index.parsed.tokens[context.calleeToken]
  )
  var matches = 0
  for item in source.index.parsed.imports:
    let binding = source.fromImportBinding(item, name)
    if binding.kind == fromImportNone:
      continue
    if binding.kind == fromImportUnsupported:
      result.fallback = fromFallbackBlocked
      return
    if item.module.startsWith("std/"):
      return
    if matches > 0:
      result.fallback = fromFallbackBlocked
      return
    inc matches
    let moduleId = workspace.resolveModule(source.fileId, item.module)
    if not moduleId.valid:
      if binding.kind == fromImportAlias:
        result.fallback = fromFallbackBlocked
      return
    let target = workspace.snapshotForFile(moduleId)
    result.signatures =
      target.projectOverloadSignatures(source.id, binding.providerName)
    if binding.kind == fromImportAlias:
      result.fallback = fromFallbackBlocked

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
      matchesImport = item.importQualifierMatches(qualifier)
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
          label: candidate.signature,
          parameters: signatureParameters(candidate.signature),
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
  let overloads = sameFileOverloadSignatures(source, context.value)
  if overloads.len > 0:
    result.signatures = overloads
  else:
    let qualifiedOverloads =
      workspace.qualifiedProjectOverloadSignatures(source, context.value)
    if qualifiedOverloads.len > 0:
      result.signatures = qualifiedOverloads
    else:
      var projectOverloads: seq[SignatureCandidate] = @[]
      var fromFallback = fromFallbackAllowed
      if context.value.qualifierToken < 0:
        let fromProject = workspace.fromProjectOverloadSignatures(source, context.value)
        projectOverloads = fromProject.signatures
        fromFallback = fromProject.fallback
      if fromFallback == fromFallbackBlocked or projectOverloads.len > 0:
        result.signatures = projectOverloads
      else:
        let project = workspace.projectSignature(source, context.value)
        if project.label.len > 0:
          result.signatures.addCandidate project
        else:
          result.signatures = stdlibSignatures(source, stdlib, context.value)
  if result.signatures.len > 0:
    result.state = signatureAvailable
