import std/sets

import ../index/occurrences
import ../index/source_index
import ../index/symbols
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
  result.state = hoverAvailable
  result.name = token.text
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
  let localOrProject =
    targetHover(workspace, source, resolveDefinition(workspace, source, byteOffset))
  if localOrProject.state == hoverAvailable:
    return localOrProject
  source.stdlibHover(stdlib, tokenIndex)
