import std/algorithm

import ../syntax/tokens
import ./scopes
import ./symbols
import ./type_ids
import ./type_index_models
import ./type_kinds
import ./type_local_resolution
import ./type_queries
import ./type_states

proc indexUfcsProcedures*(
    tokens: TokenStore,
    symbols: openArray[SourceSymbol],
    scopes: ScopeIndex,
    types: var TypeIndex,
) =
  for scopeOrdinal, scope in scopes.scopes:
    if scope.kind != scopeRoutine or scope.ownerSymbol >= uint32(symbols.len):
      continue
    let symbol = symbols[int(scope.ownerSymbol)]
    if symbol.kind notin {symbolProc, symbolFunc, symbolMethod}:
      continue
    var parameterOrdinal = -1
    let scopeId = ScopeId(uint32(scopeOrdinal + 1))
    for declarationIndex, declaration in scopes.declarations:
      if declaration.scope != scopeId or declaration.kind != declarationParameter:
        continue
      if parameterOrdinal < 0 or
          declaration.nameToken < scopes.declarations[parameterOrdinal].nameToken:
        parameterOrdinal = declarationIndex
    if parameterOrdinal < 0 or parameterOrdinal >= types.localTypeIds.len:
      continue
    let parameter = scopes.declarations[parameterOrdinal]
    let info = types.localTypeAt(tokens, scopes, parameter.nameToken)
    if info.state != typeStateResolved or not info.typeId.valid or
        info.kind == typeGenericInstance and not types.supportedGenericInstance(info):
      continue
    types.ufcsProcedures.add UfcsProcedureRecord(
      typeId: info.typeId,
      symbolOrdinal: scope.ownerSymbol,
      parameterOrdinal: uint32(parameterOrdinal),
    )
  types.ufcsProcedures.sort(
    proc(left, right: UfcsProcedureRecord): int =
      result = cmp(uint32(left.typeId), uint32(right.typeId))
      if result == 0:
        result = cmp(left.symbolOrdinal, right.symbolOrdinal)
      if result == 0:
        result = cmp(left.parameterOrdinal, right.parameterOrdinal)
  )
