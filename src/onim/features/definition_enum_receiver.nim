import std/sets

import ../index/source_index
import ../index/symbols
import ../index/type_declaration_syntax
import ../index/type_object_queries
import ../session/ids
import ../session/workspace
import ../session/workspace_models
import ../syntax/imports
import ../syntax/tokens
import ./definition_models
import ./definition_source_queries
import ./definition_symbol_target
import ./definition_visibility

proc enumReceiverInView(
    source: WorkspaceSnapshot,
    view: WorkspaceIndexView,
    name: string,
    exportedOnly: bool,
): ObjectReceiverResolution =
  if not view.valid or view.index == nil or view.id.value != source.id.value:
    return
  let matches = symbolMatches(view.index, name, exportedOnly)
  if matches.len != 1:
    return
  let symbolIndex = matches[0]
  if view.index.symbols[symbolIndex].kind != symbolType:
    return
  let declarationToken = view.index.symbols[symbolIndex].nameToken
  if not simpleEnumDeclaration(view.index.parsed.tokens, declarationToken):
    return
  let objectOrdinal = view.index.types.objectOrdinal(declarationToken)
  if objectOrdinal < 0:
    return
  let target = targetFor(source, view, symbolIndex)
  if target.kind != definitionResolved:
    return
  result.resolved = true
  result.typeTarget = target.target
  result.provider = view.index
  result.objectOrdinal = uint32(objectOrdinal)
  result.exportedOnly = exportedOnly

proc resolveEnumTypeReceiver*(
    workspace: Workspace, source: WorkspaceSnapshot, typeToken: uint32
): ObjectReceiverResolution =
  if workspace == nil or not validSource(source) or source.index == nil or
      typeToken >= uint32(source.index.parsed.tokens.len):
    return
  let name =
    source.index.parsed.tokens.tokenText(source.index.parsed.tokens[int(typeToken)])
  let localView = WorkspaceIndexView(
    valid: source.valid,
    id: source.id,
    fileId: source.fileId,
    contentGeneration: source.contentGeneration,
    index: source.index,
  )
  let local = enumReceiverInView(source, localView, name, exportedOnly = false)
  if local.resolved:
    return local
  if not workspace.graphComplete:
    return
  var found = false
  for item in source.index.parsed.imports:
    var usable = false
    case item.form
    of importModule:
      usable =
        not item.synthetic and item.alias.len == 0 and not item.conditional and
        item.excluded.len == 0
    of fromModule:
      if item.synthetic or item.alias.len > 0 or item.conditional or
          hasExcept(source.index.parsed, item):
        continue
      for symbol in item.importedSymbols:
        if sameIdentifier(symbol.name, name) and plainImported(source.text, symbol):
          usable = true
          break
    if not usable:
      continue
    let moduleId = workspace.resolveModule(source.fileId, item.module)
    if not moduleId.valid:
      continue
    let view = workspace.indexViewForFile(moduleId)
    let candidate = enumReceiverInView(source, view, name, exportedOnly = true)
    if not candidate.resolved:
      continue
    if found:
      return
    result = candidate
    found = true
