import ../syntax/tokens
import ./occurrences
import ./scope_uncertainty
import ./source_index
import ./surfaces

proc addSourceUncertainty(
    target: var set[SurfaceUncertainty], reason: ScopeUncertainty
) =
  case reason
  of scopeNestedBlock:
    discard
  of scopeConditional:
    target.incl surfaceConditional
  of scopeInclude:
    target.incl surfaceInclude
  of scopeGenerated:
    target.incl surfaceGenerated
  of scopeMalformed:
    target.incl surfaceMalformed
  else:
    target.incl surfaceUnsupported

proc addOccurrenceUncertainty(
    target: var set[SurfaceUncertainty], reason: OccurrenceUncertainty
) =
  case reason
  of uncertaintyNestedScope, uncertaintyDeclarationOrder:
    discard
  of uncertaintyConditional:
    target.incl surfaceConditional
  of uncertaintyInclude:
    target.incl surfaceInclude
  of uncertaintyGenerated:
    target.incl surfaceGenerated
  of uncertaintyMalformed:
    target.incl surfaceMalformed
  else:
    target.incl surfaceUnsupported

proc projectSurfaceInput*(
    module: string, index: SourceIndex, origin = surfaceProject
): SurfaceInput =
  result.module = module
  result.origin = origin
  if index == nil:
    result.uncertainty = {surfaceUnsupported, surfaceUniverseIncomplete}
    return
  for reason in index.scopes.uncertainty:
    result.uncertainty.addSourceUncertainty(reason)
  for reason in index.occurrences.uncertainty:
    result.uncertainty.addOccurrenceUncertainty(reason)
  if index.includes.len > 0:
    result.uncertainty.incl surfaceInclude
  if index.hasUnresolvedExports:
    result.uncertainty.incl surfaceReexport
  for symbol in index.symbols:
    if not symbol.exported or symbol.nameToken >= uint32(index.parsed.tokens.len):
      continue
    let token = index.parsed.tokens[int(symbol.nameToken)]
    if token.kind != tkIdentifier or index.parsed.tokens.tokenTextLen(token) == 0:
      result.uncertainty.incl surfaceMalformed
      continue
    result.exports.add SurfaceExportInput(
      name: index.parsed.tokens.tokenText(token),
      kind: symbol.kind,
      kindKnown: true,
      declaredArity: -1,
      shapeKnown: false,
      nameToken: symbol.nameToken,
    )
