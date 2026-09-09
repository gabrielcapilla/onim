import ../syntax/tokens
import ./symbols
import ./type_declaration_syntax
import ./type_field_syntax
import ./type_index_models

proc indexObject*(
    tokens: TokenStore, symbol: SourceSymbol, types: var TypeIndex
): bool =
  let nameToken = int(symbol.nameToken)
  let limit = typeDeclarationEnd(tokens, nameToken)
  let objectToken = objectKeyword(tokens, nameToken, limit)
  if objectToken < 0:
    return false
  var parameters: seq[uint32] = @[]
  if not parseGenericParameters(tokens, nameToken, objectToken, parameters):
    return false
  let firstField = types.fields.len
  if not parseObjectFields(tokens, nameToken, objectToken, limit, types.fields):
    types.fields.setLen(firstField)
    return false
  let firstParameter = types.genericParameterTokens.len
  for parameter in parameters:
    types.genericParameterTokens.add parameter
  types.objects.add ObjectTypeRecord(
    declarationToken: symbol.nameToken,
    firstField: uint32(firstField),
    pastField: uint32(types.fields.len),
    firstGenericParameter: uint32(firstParameter),
    pastGenericParameter: uint32(types.genericParameterTokens.len),
  )
  true

proc indexTuple*(tokens: TokenStore, symbol: SourceSymbol, types: var TypeIndex): bool =
  let nameToken = int(symbol.nameToken)
  let limit = typeDeclarationEnd(tokens, nameToken)
  let tupleToken = tupleKeyword(tokens, nameToken, limit)
  if tupleToken < 0:
    return false
  let firstField = types.fields.len
  if not parseTupleFields(tokens, tupleToken, limit, types.fields):
    types.fields.setLen(firstField)
    return false
  types.objects.add ObjectTypeRecord(
    declarationToken: symbol.nameToken,
    firstField: uint32(firstField),
    pastField: uint32(types.fields.len),
    firstGenericParameter: uint32(types.genericParameterTokens.len),
    pastGenericParameter: uint32(types.genericParameterTokens.len),
  )
  true

proc indexEnum*(tokens: TokenStore, symbol: SourceSymbol, types: var TypeIndex): bool =
  let nameToken = int(symbol.nameToken)
  let limit = typeDeclarationEnd(tokens, nameToken)
  let enumToken = enumKeyword(tokens, nameToken, limit)
  if enumToken < 0:
    return false
  let firstField = types.fields.len
  if not parseEnumFields(tokens, nameToken, enumToken, limit, types.fields):
    types.fields.setLen(firstField)
    return false
  types.objects.add ObjectTypeRecord(
    declarationToken: symbol.nameToken,
    firstField: uint32(firstField),
    pastField: uint32(types.fields.len),
    firstGenericParameter: uint32(types.genericParameterTokens.len),
    pastGenericParameter: uint32(types.genericParameterTokens.len),
  )
  true
