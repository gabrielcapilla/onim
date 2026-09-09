import ./definition_models
import ../index/bindings
import ../index/source_index
import ../session/workspace_models
import ../syntax/tokens

proc localTargetHasCompetingDeclaration*(
    source: WorkspaceSnapshot, target: DefinitionTarget
): bool =
  if target.kind != targetDeclaration:
    return true
  if source.index == nil or target.nameToken >= uint32(source.index.parsed.tokens.len):
    return true
  let binding = source.index.resolveBinding(target.nameToken)
  binding.state != bindingResolved or binding.declarationToken != target.nameToken
