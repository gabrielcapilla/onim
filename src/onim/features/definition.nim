import std/strutils

import ../index/source_index
import ../index/symbols
import ../session/ids
import ../session/workspace
import ../syntax/imports
import ../syntax/lexer

type
  DefinitionResolutionKind* = enum
    definitionUnknown
    definitionUnresolved
    definitionAmbiguous
    definitionResolved

  DefinitionTarget* = object
    snapshotId*: SnapshotId
    fileId*: FileId
    contentGeneration*: ContentGeneration
    nameToken*: uint32

  DefinitionResolution* = object
    kind*: DefinitionResolutionKind
    target*: DefinitionTarget

proc unknownResolution(kind = definitionUnknown): DefinitionResolution =
  DefinitionResolution(kind: kind)

proc validSource(source: WorkspaceSnapshot): bool =
  source.valid and source.index != nil and
    source.index.contentHash == contentFingerprint(source.text) and
    source.index.byteLength == source.text.len

proc symbolMatches(index: SourceIndex, name: string, exportedOnly = false): seq[int] =
  if index == nil:
    return
  let wanted = identifierKey(name)
  if wanted.len == 0:
    return
  for symbolIndex, symbol in index.symbols:
    let tokenIndex = int(symbol.nameToken)
    if tokenIndex < 0 or tokenIndex >= index.parsed.tokens.len:
      continue
    if exportedOnly and not symbol.exported:
      continue
    if identifierKey(index.parsed.tokens[tokenIndex].text) == wanted:
      result.add symbolIndex

proc routineKind(kind: SourceSymbolKind): bool =
  kind in {
    symbolProc, symbolFunc, symbolIterator, symbolMethod, symbolMacro, symbolTemplate,
    symbolConverter,
  }

proc routineHasBody[T](tokens: T, symbol: SourceSymbol): bool =
  let nameIndex = int(symbol.nameToken)
  if nameIndex < 0 or nameIndex + 1 >= tokens.len:
    return false
  var nesting = 0
  for cursor in nameIndex + 1 ..< tokens.len:
    if cursor > nameIndex + 1 and tokens[cursor].line > tokens[nameIndex].line and
        tokens[cursor].column == 0:
      break
    case tokens[cursor].text
    of "(", "[", "{":
      inc nesting
    of ")", "]", "}":
      if nesting > 0:
        dec nesting
    of "=":
      if nesting == 0:
        return true
    else:
      discard
  false

proc completeSymbol(index: SourceIndex, symbolIndex: int): bool =
  if index == nil or symbolIndex < 0 or symbolIndex >= index.symbols.len:
    return false
  let symbol = index.symbols[symbolIndex]
  if int(symbol.nameToken) >= index.parsed.tokens.len:
    return false
  not symbol.kind.routineKind or routineHasBody(index.parsed.tokens, symbol)

proc targetFor(
    source: WorkspaceSnapshot, view: WorkspaceIndexView, symbolIndex: int
): DefinitionResolution =
  if not view.valid or view.index == nil or view.id.value != source.id.value or
      symbolIndex < 0 or symbolIndex >= view.index.symbols.len:
    return unknownResolution(definitionUnresolved)
  let symbol = view.index.symbols[symbolIndex]
  if int(symbol.nameToken) >= view.index.parsed.tokens.len:
    return unknownResolution()
  if not completeSymbol(view.index, symbolIndex):
    return unknownResolution()
  result.kind = definitionResolved
  result.target = DefinitionTarget(
    snapshotId: source.id,
    fileId: view.fileId,
    contentGeneration: view.contentGeneration,
    nameToken: symbol.nameToken,
  )

proc addTarget(targets: var seq[DefinitionTarget], target: DefinitionTarget) =
  for existing in targets:
    if existing.fileId.value == target.fileId.value and
        existing.nameToken == target.nameToken:
      return
  targets.add target

proc finishTargets(
    targets: seq[DefinitionTarget], unresolved: bool
): DefinitionResolution =
  if unresolved:
    return unknownResolution(definitionUnresolved)
  if targets.len == 0:
    return unknownResolution()
  if targets.len > 1:
    return unknownResolution(definitionAmbiguous)
  result.kind = definitionResolved
  result.target = targets[0]

proc hasExcept(imports: SourceImports, item: ImportInfo): bool =
  for token in imports.tokens:
    if token.startOffset < item.startOffset or token.endOffset > item.endOffset:
      continue
    if token.isKeyword(kwExcept):
      return true
  false

proc plainImported(source: string, symbol: ImportSymbol): bool =
  if symbol.startOffset < 0 or symbol.endOffset < symbol.startOffset or
      symbol.endOffset > source.len:
    return false
  source[symbol.startOffset ..< symbol.endOffset].strip(chars = {'`'}) == symbol.name

proc fromBindingState(
    source: WorkspaceSnapshot, name: string
): tuple[found, uncertain: bool] =
  for item in source.index.parsed.imports:
    if item.form != fromModule:
      continue
    for symbol in item.importedSymbols:
      if not sameIdentifier(symbol.name, name):
        continue
      result.found = true
      if item.conditional or item.synthetic or hasExcept(source.index.parsed, item) or
          not plainImported(source.text, symbol):
        result.uncertain = true

proc qualifiedMember[T](tokens: T, tokenIndex: int): tuple[qualifier, member: int] =
  result = (-1, -1)
  if tokenIndex < 2 or tokens[tokenIndex - 1].text != ".":
    return
  let qualifier = tokenIndex - 2
  if tokens[qualifier].kind != tkIdentifier or
      tokens[qualifier].line != tokens[tokenIndex].line or
      (qualifier > 0 and tokens[qualifier - 1].text == ".") or
      (tokenIndex + 1 < tokens.len and tokens[tokenIndex + 1].text == "."):
    return
  result = (qualifier, tokenIndex)

proc qualifierMatches(item: ImportInfo, qualifier: string): bool =
  if item.alias.len > 0:
    sameIdentifier(item.alias, qualifier)
  else:
    sameIdentifier(moduleLeaf(item.module), qualifier)

proc resolveQualified(
    workspace: Workspace, source: WorkspaceSnapshot, qualifier, member: string
): DefinitionResolution =
  let localQualifier = symbolMatches(source.index, qualifier)
  if localQualifier.len > 0:
    return unknownResolution()

  var targets: seq[DefinitionTarget] = @[]
  var matched = false
  var unresolved = false
  for item in source.index.parsed.imports:
    if item.form != importModule or item.synthetic or
        not item.qualifierMatches(qualifier):
      continue
    matched = true
    if item.conditional or hasExcept(source.index.parsed, item):
      return unknownResolution()
    let moduleId = workspace.resolveModule(source.fileId, item.module)
    if not moduleId.valid:
      unresolved = true
      continue
    let view = workspace.indexViewForFile(moduleId)
    if not view.valid or view.index == nil:
      unresolved = true
      continue
    let matches = symbolMatches(view.index, member, exportedOnly = true)
    if matches.len > 1:
      return unknownResolution(definitionAmbiguous)
    for symbolIndex in matches:
      let candidate = targetFor(source, view, symbolIndex)
      if candidate.kind != definitionResolved:
        return candidate
      targets.addTarget(candidate.target)
  if not matched:
    return unknownResolution()
  finishTargets(targets, unresolved)

proc resolveFrom(
    workspace: Workspace, source: WorkspaceSnapshot, name: string
): DefinitionResolution =
  var targets: seq[DefinitionTarget] = @[]
  var matched = false
  var unresolved = false
  for item in source.index.parsed.imports:
    if item.form != fromModule or item.synthetic:
      continue
    for imported in item.importedSymbols:
      if not sameIdentifier(imported.name, name):
        continue
      matched = true
      if item.conditional or hasExcept(source.index.parsed, item) or
          not plainImported(source.text, imported):
        return unknownResolution()
      let moduleId = workspace.resolveModule(source.fileId, item.module)
      if not moduleId.valid:
        unresolved = true
        continue
      let view = workspace.indexViewForFile(moduleId)
      if not view.valid or view.index == nil:
        unresolved = true
        continue
      let matches = symbolMatches(view.index, imported.name, exportedOnly = true)
      if matches.len > 1:
        return unknownResolution(definitionAmbiguous)
      for symbolIndex in matches:
        let candidate = targetFor(source, view, symbolIndex)
        if candidate.kind != definitionResolved:
          return candidate
        targets.addTarget(candidate.target)
  if not matched:
    return unknownResolution()
  finishTargets(targets, unresolved)

proc resolveDefinition*(
    workspace: Workspace, source: WorkspaceSnapshot, byteOffset: int
): DefinitionResolution =
  result = unknownResolution()
  if workspace == nil or not validSource(source):
    return
  let tokenIndex = tokenAtOffset(source.index.parsed.tokens, byteOffset)
  if tokenIndex < 0:
    return
  let token = source.index.parsed.tokens[tokenIndex]
  if source.index.parsed.tokenInsideImport(token):
    return

  let matches = symbolMatches(source.index, token.text)
  let declarationIndex = source.index.symbols.symbolToken(uint32(tokenIndex))
  if declarationIndex >= 0:
    if matches.len != 1:
      return unknownResolution(definitionAmbiguous)
    if not completeSymbol(source.index, declarationIndex):
      return
    result.kind = definitionResolved
    result.target = DefinitionTarget(
      snapshotId: source.id,
      fileId: source.fileId,
      contentGeneration: source.contentGeneration,
      nameToken: uint32(tokenIndex),
    )
    return

  let qualified = qualifiedMember(source.index.parsed.tokens, tokenIndex)
  if qualified.member >= 0:
    if source.index.parsed.tokens[qualified.qualifier].column != 0:
      return
    if source.index.parsed.tokens[qualified.qualifier].startOffset < 0:
      return
    return resolveQualified(
      workspace,
      source,
      source.index.parsed.tokens[qualified.qualifier].text,
      token.text,
    )
  if tokenIndex + 1 < source.index.parsed.tokens.len and
      source.index.parsed.tokens[tokenIndex + 1].text == ".":
    return
  if token.column != 0:
    return

  let fromState = fromBindingState(source, token.text)
  if matches.len > 1:
    return unknownResolution(definitionAmbiguous)
  if matches.len == 1:
    let declaration =
      source.index.parsed.tokens[int(source.index.symbols[matches[0]].nameToken)]
    if declaration.startOffset >= token.startOffset:
      return
    if fromState.found:
      return unknownResolution()
    if not completeSymbol(source.index, matches[0]):
      return
    result.kind = definitionResolved
    result.target = DefinitionTarget(
      snapshotId: source.id,
      fileId: source.fileId,
      contentGeneration: source.contentGeneration,
      nameToken: source.index.symbols[matches[0]].nameToken,
    )
    return
  if fromState.uncertain:
    return
  result = resolveFrom(workspace, source, token.text)
