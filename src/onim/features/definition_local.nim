import ../index/bindings
import ../index/source_index
import ../session/workspace_models
import ../syntax/import_queries
import ../syntax/tokens
import ./definition_models
import ./definition_resolution_results
import ./definition_source_queries

proc localTarget(
    source: WorkspaceSnapshot, declarationToken: uint32
): DefinitionResolution =
  if declarationToken >= uint32(source.index.parsed.tokens.len):
    return unknownResolution()
  result.kind = definitionResolved
  result.target = DefinitionTarget(
    kind: targetDeclaration,
    snapshotId: source.id,
    fileId: source.fileId,
    contentGeneration: source.contentGeneration,
    nameToken: declarationToken,
  )

proc resolveLocalDefinitionAtToken*(
    source: WorkspaceSnapshot, tokenIndex: int
): DefinitionResolution =
  if not validSource(source) or not source.index.bindingsReady or tokenIndex < 0 or
      tokenIndex >= source.index.parsed.tokens.len:
    return unknownResolution()
  let token = source.index.parsed.tokens[tokenIndex]
  if token.kind != tkIdentifier or source.index.parsed.tokenInsideImport(token):
    return unknownResolution()
  let binding = source.index.resolveBinding(uint32(tokenIndex))
  case binding.state
  of bindingAmbiguous:
    unknownResolution(definitionAmbiguous)
  of bindingResolved:
    localTarget(source, binding.declarationToken)
  of bindingUnknown:
    unknownResolution()

proc resolveLocalDefinitionAtName*(
    source: WorkspaceSnapshot, tokenIndex: int, name: string
): DefinitionResolution =
  if not validSource(source) or not source.index.bindingsReady or tokenIndex < 0 or
      tokenIndex >= source.index.parsed.tokens.len:
    return unknownResolution()
  let binding = source.index.resolveBindingAtName(uint32(tokenIndex), name)
  case binding.state
  of bindingAmbiguous:
    unknownResolution(definitionAmbiguous)
  of bindingResolved:
    localTarget(source, binding.declarationToken)
  of bindingUnknown:
    unknownResolution()
