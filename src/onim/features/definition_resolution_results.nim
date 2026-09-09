import ../index/types
import ../index/type_states
import ../session/ids
import ./definition_models

proc unknownResolution*(kind = definitionUnknown): DefinitionResolution =
  DefinitionResolution(kind: kind)

proc typeStateForDefinition*(kind: DefinitionResolutionKind): TypeState {.inline.} =
  case kind
  of definitionUnresolved: typeStateUnresolved
  of definitionAmbiguous: typeStateAmbiguous
  of definitionResolved: typeStateResolved
  of definitionUnknown, definitionUnsupported: typeStateUnknown

proc addTarget*(targets: var seq[DefinitionTarget], target: DefinitionTarget) =
  for existing in targets:
    if existing.kind == target.kind and existing.fileId.value == target.fileId.value and
        existing.nameToken == target.nameToken:
      return
  targets.add target

proc finishTargets*(
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
