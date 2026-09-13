import std/algorithm

import ../syntax/tokens
import ./scopes
import ./symbols
import ./type_declaration_index
import ./type_expression_syntax
import ./type_field_syntax
import ./type_ids
import ./type_kinds
import ./type_index_models
import ./type_interning
import ./type_annotation_syntax
import ./type_local_resolution
import ./type_routine_returns
import ./type_ufcs_index
import ./type_tuple_literals

proc indexTypes*(
    tokens: TokenStore, symbols: openArray[SourceSymbol], scopes: ScopeIndex
): TypeIndex =
  result.records = @[]
  result.genericArgumentTypeIds = @[]
  result.localTupleObjects = @[]
  result.localTupleFields = @[]
  result.genericParameterTokens = @[]
  discard result.internType(typeBool)
  discard result.internType(typeChar)
  discard result.internType(typeString)
  discard result.internType(typeInt)
  discard result.internType(typeFloat)
  result.localTypeIds = newSeq[TypeId](scopes.declarations.len)
  for declarationIndex, declaration in scopes.declarations:
    let descriptor = declarationTypeDescriptor(tokens, declaration)
    result.localTypeIds[declarationIndex] = result.internDescriptor(descriptor)
    var tupleFields: seq[ObjectField] = @[]
    let split = splitDeclaration(tokens, declaration)
    let tupleLiteral =
      if descriptor.kind == typeNamed and descriptor.nameToken == declaration.nameToken:
        parseTupleLiteralFields(
          tokens, split.equals + 1, int(declaration.pastToken), tupleFields
        )
      elif descriptor.kind == typeSeq and descriptor.baseKind == typeNamed and
        descriptor.baseNameToken == declaration.nameToken:
        sequenceLiteralTupleFields(
          tokens, split.equals + 1, int(declaration.pastToken), tupleFields
        )
      else:
        false
    if tupleLiteral:
      let firstField = result.localTupleFields.len
      result.localTupleFields.add tupleFields
      result.localTupleObjects.add ObjectTypeRecord(
        declarationToken: declaration.nameToken,
        firstField: uint32(firstField),
        pastField: uint32(result.localTupleFields.len),
      )
  result.ufcsProcedures = @[]
  indexUfcsProcedures(tokens, symbols, scopes, result)
  result.routineReturnTypeIds = newSeq[TypeId](symbols.len)
  for symbolIndex, symbol in symbols:
    if symbol.kind in {symbolVar, symbolLet, symbolConst}:
      discard result.internDescriptor(moduleValueDescriptor(tokens, symbol))
    result.routineReturnTypeIds[symbolIndex] =
      result.internDescriptor(routineReturnSpan(tokens, symbol).descriptor)
    if symbol.kind == symbolType:
      if not indexObject(tokens, symbol, result):
        if not indexTuple(tokens, symbol, result):
          discard indexEnum(tokens, symbol, result)
  result.localTupleObjects.sort(
    proc(left, right: ObjectTypeRecord): int =
      cmp(left.declarationToken, right.declarationToken)
  )
