import std/[sets, strutils]

import ../index/occurrences
import ../index/scopes
import ../index/source_index
import ../index/symbols
import ../index/types
import ../session/workspace
import ../stdlib/map
import ../syntax/imports
import ../syntax/lexer
import ./definition

type
  HoverState* = enum
    hoverUnavailable
    hoverAvailable

  HoverInfo* = object
    state*: HoverState
    name*: string
    module*: string
    kind*: string
    signature*: string

proc targetHover(
    workspace: Workspace, source: WorkspaceSnapshot, resolution: DefinitionResolution
): HoverInfo =
  if resolution.kind != definitionResolved:
    return
  let view = workspace.indexViewForFile(resolution.target.fileId)
  if not view.valid or view.index == nil or
      resolution.target.nameToken >= uint32(view.index.parsed.tokens.len):
    return
  let token = view.index.parsed.tokens[int(resolution.target.nameToken)]
  if token.kind != tkIdentifier:
    return

  proc localTypeText(typeSource: WorkspaceSnapshot, typeInfo: LocalTypeInfo): string =
    case typeInfo.kind
    of localTypeBool:
      "bool"
    of localTypeChar:
      "char"
    of localTypeString:
      "string"
    of localTypeInt:
      "int"
    of localTypeUnknown:
      ""
    of localTypeNamed:
      if not typeSource.valid or typeSource.index == nil or
          typeInfo.firstToken >= typeInfo.pastToken or
          typeInfo.pastToken > uint32(typeSource.index.parsed.tokens.len):
        return
      let first = typeSource.index.parsed.tokens[int(typeInfo.firstToken)]
      let last = typeSource.index.parsed.tokens[int(typeInfo.pastToken) - 1]
      if first.startOffset < 0 or last.endOffset <= first.startOffset or
          last.endOffset > typeSource.text.len:
        return
      typeSource.text[first.startOffset ..< last.endOffset].strip

  proc localSignature(): string =
    if uint32(resolution.target.fileId) != uint32(source.fileId) or
        uint64(resolution.target.snapshotId) != uint64(source.id) or
        uint64(resolution.target.contentGeneration) != uint64(source.contentGeneration):
      return
    let declarationOrdinal =
      source.index.scopes.declarationOrdinalAt(resolution.target.nameToken)
    if declarationOrdinal < 0 or
        declarationOrdinal >= source.index.scopes.declarations.len:
      return
    let localType = workspace.resolveLocalType(source, resolution.target.nameToken)
    if localType.info.kind == localTypeUnknown:
      return
    let typeInfo = localType.info
    var typeSource = source
    if uint32(localType.fileId) != uint32(source.fileId):
      typeSource = workspace.snapshotForFile(localType.fileId)
      if not typeSource.valid or uint64(typeSource.id) != uint64(source.id) or
          uint64(typeSource.contentGeneration) != uint64(localType.contentGeneration) or
          typeSource.index == nil or not typeSource.index.nativeIndexSafe():
        return
    elif uint64(localType.contentGeneration) != uint64(source.contentGeneration) or
        uint64(localType.snapshotId) != uint64(source.id):
      return
    let typeName = localTypeText(typeSource, typeInfo)
    if typeName.len == 0:
      return
    let declaration = source.index.scopes.declarations[declarationOrdinal]
    let prefix =
      case declaration.kind
      of declarationParameter: ""
      of declarationLet: "let "
      of declarationVar: "var "
      of declarationConst: "const "
    prefix & token.text & ": " & typeName

  result.state = hoverAvailable
  result.name = token.text
  case resolution.target.kind
  of targetObjectField:
    result.kind = "field"
  of targetDeclaration:
    result.signature = localSignature()
  if uint32(view.fileId) != uint32(source.fileId):
    result.module = workspace.moduleForPath(view.path)

proc qualifierIndex(index: SourceIndex, tokenIndex: uint32): int =
  if index == nil:
    return -1
  for qualified in index.occurrences.qualified:
    if qualified.memberToken == tokenIndex:
      let candidate = int(qualified.qualifierToken)
      if candidate >= 0 and candidate < index.parsed.tokens.len:
        return candidate
  -1

proc qualifierMatches(item: ImportInfo, qualifier: string): bool {.inline.} =
  if item.alias.len > 0:
    return sameIdentifier(item.alias, qualifier)
  sameIdentifier(moduleLeaf(item.module), qualifier)

proc stdlibCandidate(
    stdlib: StdlibMap, item: ImportInfo, name, qualifier: string
): SymbolCandidate =
  if stdlib == nil or item.synthetic or item.conditional or item.excluded.len > 0:
    return
  if qualifier.len > 0:
    if item.form != importModule or not item.qualifierMatches(qualifier):
      return
  elif item.form == importModule and item.alias.len > 0:
    return
  elif item.form == fromModule:
    var imported = false
    for symbol in item.importedSymbols:
      if sameIdentifier(symbol.name, name):
        imported = true
        break
    if not imported:
      return
  elif item.form != importModule:
    return
  for candidate in stdlib.candidatesFor(name, ""):
    if sameModule(candidate.module, item.module):
      return candidate

proc stdlibHover(
    source: WorkspaceSnapshot, stdlib: StdlibMap, tokenIndex: int
): HoverInfo =
  if stdlib == nil or tokenIndex < 0 or tokenIndex >= source.index.parsed.tokens.len:
    return
  let token = source.index.parsed.tokens[tokenIndex]
  var qualifier = ""
  let qualifierToken = source.index.qualifierIndex(uint32(tokenIndex))
  if qualifierToken >= 0:
    qualifier = source.index.parsed.tokens[qualifierToken].text
  for item in source.index.parsed.imports:
    let candidate = stdlibCandidate(stdlib, item, token.text, qualifier)
    if candidate.module.len == 0:
      continue
    if result.state == hoverAvailable and result.module != candidate.module:
      return HoverInfo()
    result.state = hoverAvailable
    result.name = candidate.name
    result.module = candidate.module
    result.kind = candidate.kind
    result.signature = candidate.signature

proc resolveHover*(
    workspace: Workspace, source: WorkspaceSnapshot, byteOffset: int, stdlib: StdlibMap
): HoverInfo =
  if workspace == nil or not source.valid or source.index == nil:
    return
  let tokenIndex = tokenAtOffset(source.index.parsed.tokens, byteOffset)
  if tokenIndex < 0:
    return
  let token = source.index.parsed.tokens[tokenIndex]
  if token.kind != tkIdentifier or source.index.parsed.tokenInsideImport(token):
    return
  let resolution = resolveDefinition(workspace, source, byteOffset)
  if resolution.kind != definitionUnknown:
    return targetHover(workspace, source, resolution)
  source.stdlibHover(stdlib, tokenIndex)
