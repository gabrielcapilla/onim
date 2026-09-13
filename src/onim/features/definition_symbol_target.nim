import ../index/source_index
import ../session/ids
import ../session/workspace_models
import ./definition_models
import ./definition_resolution_results
import ./definition_symbol_completeness
import ../syntax/tokens

proc targetFor*(
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
    kind: targetDeclaration,
    snapshotId: source.id,
    fileId: view.fileId,
    contentGeneration: view.contentGeneration,
    nameToken: symbol.nameToken,
  )

proc resolveSymbolTarget*(
    source: WorkspaceSnapshot, view: WorkspaceIndexView, symbolIndex: int
): DefinitionResolution =
  targetFor(source, view, symbolIndex)
