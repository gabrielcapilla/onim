import std/algorithm

import ../syntax/lexer
import ./scopes
import ./symbols

type
  ObjectFieldVisibility* = enum
    objectFieldPrivate
    objectFieldExported

  TypeId* = distinct uint32

  TypeKind* = enum
    typeUnknown
    typeNamed
    typeBool
    typeChar
    typeString
    typeInt
    typeFloat
    typeInt8
    typeInt16
    typeInt32
    typeInt64
    typeUInt
    typeUInt8
    typeUInt16
    typeUInt32
    typeUInt64
    typeFloat32
    typeFloat64
    typeFloat128
    typeSeq
    typeRef
    typeArray
    typeGenericInstance

  TypeState* = enum
    typeStateUnknown
    typeStateUnresolved
    typeStateAmbiguous
    typeStateGenerated
    typeStateResolved

  ObjectTypeRecord* = object
    declarationToken*: uint32
    firstField*: uint32
    pastField*: uint32
    firstGenericParameter*: uint32
    pastGenericParameter*: uint32

  ObjectField* = object
    nameToken*: uint32
    visibility*: ObjectFieldVisibility

  LocalTypeForm* = enum
    localTypeFormUnknown
    localTypeFormAnnotation
    localTypeFormCall
    localTypeFormLiteral

  TypeRecord* = object
    kind*: TypeKind
    nameToken*: uint32
    baseType*: TypeId
    extent*: uint32
    firstArgument*: uint32
    pastArgument*: uint32

  UfcsProcedureRecord* = object
    typeId*: TypeId
    symbolOrdinal*: uint32
    parameterOrdinal*: uint32

  GenericArgumentDescriptor = object
    kind: TypeKind
    nameToken: uint32

  TypeDescriptor = object
    kind: TypeKind
    nameToken: uint32
    baseKind: TypeKind
    baseNameToken: uint32
    extent: uint32
    genericArguments: seq[GenericArgumentDescriptor]

  LocalTypeInfo* = object
    kind*: TypeKind
    state*: TypeState
    form*: LocalTypeForm
    typeId*: TypeId
    typeToken*: uint32
    firstToken*: uint32
    pastToken*: uint32

  TypeIndex* = object
    records*: seq[TypeRecord]
    genericArgumentTypeIds*: seq[TypeId]
    objects*: seq[ObjectTypeRecord]
    fields*: seq[ObjectField]
    localTupleObjects*: seq[ObjectTypeRecord]
    localTupleFields*: seq[ObjectField]
    genericParameterTokens*: seq[uint32]
    localTypeIds*: seq[TypeId]
    routineReturnTypeIds*: seq[TypeId]
    ufcsProcedures*: seq[UfcsProcedureRecord]

const
  InvalidTypeToken* = high(uint32)
  InvalidTypeId* = TypeId(0'u32)
  primitiveTypeKinds = [
    typeBool, typeChar, typeString, typeInt, typeFloat, typeInt8, typeInt16, typeInt32,
    typeInt64, typeUInt, typeUInt8, typeUInt16, typeUInt32, typeUInt64, typeFloat32,
    typeFloat64, typeFloat128,
  ]

proc valid*(id: TypeId): bool {.inline.} =
  uint32(id) != 0'u32

proc `==`*(left, right: TypeId): bool {.inline.} =
  uint32(left) == uint32(right)

proc typeKind*(types: TypeIndex, id: TypeId): TypeKind {.inline.} =
  let ordinal = int(uint32(id)) - 1
  if ordinal >= 0 and ordinal < types.records.len:
    types.records[ordinal].kind
  else:
    typeUnknown

proc typeBase*(types: TypeIndex, id: TypeId): TypeId {.inline.} =
  let ordinal = int(uint32(id)) - 1
  if ordinal >= 0 and ordinal < types.records.len:
    types.records[ordinal].baseType
  else:
    InvalidTypeId

proc typeNameToken*(types: TypeIndex, id: TypeId): uint32 {.inline.} =
  let ordinal = int(uint32(id)) - 1
  if ordinal >= 0 and ordinal < types.records.len and
      types.records[ordinal].kind == typeNamed:
    types.records[ordinal].nameToken
  else:
    InvalidTypeToken

proc genericArgumentCount*(types: TypeIndex, id: TypeId): int {.inline.} =
  let ordinal = int(uint32(id)) - 1
  if ordinal < 0 or ordinal >= types.records.len or
      types.records[ordinal].kind != typeGenericInstance:
    return 0
  let record = types.records[ordinal]
  if record.pastArgument < record.firstArgument or
      record.pastArgument > uint32(types.genericArgumentTypeIds.len):
    return 0
  int(record.pastArgument - record.firstArgument)

proc genericArgumentType*(types: TypeIndex, id: TypeId, index: int): TypeId {.inline.} =
  let ordinal = int(uint32(id)) - 1
  if ordinal < 0 or ordinal >= types.records.len or
      types.records[ordinal].kind != typeGenericInstance:
    return InvalidTypeId
  let record = types.records[ordinal]
  let argument = int(record.firstArgument) + index
  if index < 0 or argument < int(record.firstArgument) or
      argument >= int(record.pastArgument) or
      argument >= types.genericArgumentTypeIds.len:
    return InvalidTypeId
  types.genericArgumentTypeIds[argument]

proc namedTypeId*(types: TypeIndex, id: TypeId): TypeId {.inline.} =
  case types.typeKind(id)
  of typeNamed:
    id
  of typeRef:
    let base = types.typeBase(id)
    if types.typeKind(base) == typeNamed: base else: InvalidTypeId
  else:
    InvalidTypeId

proc primitiveTypeName*(kind: TypeKind): string {.inline.} =
  case kind
  of typeBool: "bool"
  of typeChar: "char"
  of typeString: "string"
  of typeInt: "int"
  of typeFloat: "float"
  of typeInt8: "int8"
  of typeInt16: "int16"
  of typeInt32: "int32"
  of typeInt64: "int64"
  of typeUInt: "uint"
  of typeUInt8: "uint8"
  of typeUInt16: "uint16"
  of typeUInt32: "uint32"
  of typeUInt64: "uint64"
  of typeFloat32: "float32"
  of typeFloat64: "float64"
  of typeFloat128: "float128"
  else: ""

proc isPrimitiveType*(kind: TypeKind): bool {.inline.} =
  for primitive in primitiveTypeKinds:
    if kind == primitive:
      return true
  false

proc validTypeShape(
    kind: TypeKind, nameToken: uint32, baseType: TypeId, extent = 0'u32
): bool {.inline.} =
  case kind
  of typeNamed:
    nameToken != InvalidTypeToken and not baseType.valid and extent == 0'u32
  of typeSeq, typeRef:
    nameToken == InvalidTypeToken and baseType.valid and extent == 0'u32
  of typeArray:
    nameToken == InvalidTypeToken and baseType.valid
  of typeGenericInstance:
    nameToken != InvalidTypeToken and baseType.valid and extent == 0'u32
  of typeUnknown:
    false
  else:
    nameToken == InvalidTypeToken and not baseType.valid and extent == 0'u32

proc sameGenericArguments(
    types: TypeIndex, record: TypeRecord, arguments: seq[TypeId]
): bool {.inline.} =
  if record.pastArgument < record.firstArgument or
      record.pastArgument > uint32(types.genericArgumentTypeIds.len) or
      int(record.pastArgument - record.firstArgument) != arguments.len:
    return false
  for index, argument in arguments:
    if types.genericArgumentTypeIds[int(record.firstArgument) + index] != argument:
      return false
  true

proc sameGenericRecordArguments(
    types: TypeIndex, left, right: TypeRecord
): bool {.inline.} =
  if left.pastArgument < left.firstArgument or right.pastArgument < right.firstArgument or
      left.pastArgument > uint32(types.genericArgumentTypeIds.len) or
      right.pastArgument > uint32(types.genericArgumentTypeIds.len) or
      left.pastArgument - left.firstArgument != right.pastArgument - right.firstArgument:
    return false
  for index in 0 ..< int(left.pastArgument - left.firstArgument):
    if types.genericArgumentTypeIds[int(left.firstArgument) + index] !=
        types.genericArgumentTypeIds[int(right.firstArgument) + index]:
      return false
  true

proc typeIdFor(
    types: TypeIndex,
    kind: TypeKind,
    nameToken = InvalidTypeToken,
    baseType = InvalidTypeId,
    extent = 0'u32,
    genericArguments: seq[TypeId] = @[],
): TypeId {.inline.} =
  if not validTypeShape(kind, nameToken, baseType, extent):
    return InvalidTypeId
  if kind == typeGenericInstance and
      (genericArguments.len == 0 or genericArguments[0] != baseType):
    return InvalidTypeId
  for ordinal, record in types.records:
    if record.kind == kind and record.nameToken == nameToken and
        record.baseType == baseType and record.extent == extent and
        types.sameGenericArguments(record, genericArguments):
      return TypeId(uint32(ordinal + 1))
  InvalidTypeId

proc internType(
    types: var TypeIndex,
    kind: TypeKind,
    nameToken = InvalidTypeToken,
    baseType = InvalidTypeId,
    extent = 0'u32,
    genericArguments: seq[TypeId] = @[],
): TypeId =
  let existing = types.typeIdFor(kind, nameToken, baseType, extent, genericArguments)
  if existing.valid:
    return existing
  if not validTypeShape(kind, nameToken, baseType, extent):
    return InvalidTypeId
  if kind == typeGenericInstance and
      (genericArguments.len == 0 or genericArguments[0] != baseType):
    return InvalidTypeId
  let firstArgument = uint32(types.genericArgumentTypeIds.len)
  types.genericArgumentTypeIds.add genericArguments
  types.records.add TypeRecord(
    kind: kind,
    nameToken: nameToken,
    baseType: baseType,
    extent: extent,
    firstArgument: firstArgument,
    pastArgument: uint32(types.genericArgumentTypeIds.len),
  )
  TypeId(uint32(types.records.len))

proc validNameToken(tokens: TokenStore, index: int): bool {.inline.} =
  if index < 0 or index >= tokens.len:
    return false
  let token = tokens[index]
  token.kind == tkIdentifier and token.validIdentifier and not token.isStropped and
    not isNimKeyword(token)

proc genericParameterBounds(
    tokens: TokenStore, nameToken, limit: int
): tuple[first, past, after: int, present, valid: bool] =
  result.after = nameToken + 1
  result.valid = true
  if nameToken < 0 or nameToken >= limit:
    result.valid = false
    return
  var cursor = nameToken + 1
  if cursor < limit and tokens.tokenTextEquals(tokens[cursor], "*"):
    inc cursor
  if cursor >= limit or not tokens.tokenTextEquals(tokens[cursor], "["):
    result.after = cursor
    return
  result.present = true
  result.first = cursor + 1
  inc cursor
  while cursor < limit:
    if tokens.tokenTextEquals(tokens[cursor], "["):
      result.valid = false
      return
    if tokens.tokenTextEquals(tokens[cursor], "]"):
      if cursor == result.first:
        result.valid = false
        return
      result.past = cursor
      result.after = cursor + 1
      return
    inc cursor
  result.valid = false

proc typeDeclarationEnd(tokens: TokenStore, nameToken: int): int =
  if nameToken < 0 or nameToken >= tokens.len:
    return -1
  let line = tokens[nameToken].line
  var column = tokens[nameToken].column
  var cursor = nameToken - 1
  while cursor >= 0 and tokens[cursor].line == line:
    if tokens[cursor].isKeyword(kwType):
      column = tokens[cursor].column
      break
    dec cursor
  result = tokens.len
  for index in nameToken + 1 ..< tokens.len:
    if tokens[index].line > line and tokens[index].column <= column:
      return index

proc objectKeyword(tokens: TokenStore, nameToken, limit: int): int =
  if nameToken < 0 or nameToken >= limit:
    return -1
  var cursor = nameToken + 1
  if cursor < limit and tokens.tokenTextEquals(tokens[cursor], "*"):
    inc cursor
  let generic = genericParameterBounds(tokens, nameToken, limit)
  if not generic.valid:
    return -1
  cursor = generic.after
  if cursor >= limit or not tokens.tokenTextEquals(tokens[cursor], "=") or
      tokens[cursor].line != tokens[nameToken].line:
    return -1
  inc cursor
  if cursor < limit and
      (tokens[cursor].isKeyword(kwRef) or tokens[cursor].isKeyword(kwPtr)):
    inc cursor
  if cursor >= limit or not tokens[cursor].isKeyword(kwObject) or
      tokens[cursor].line != tokens[nameToken].line:
    return -1
  result = cursor
  inc cursor
  if cursor < limit and tokens[cursor].line == tokens[result].line:
    return -1

proc parseGenericParameters(
    tokens: TokenStore, nameToken, objectToken: int, parameters: var seq[uint32]
): bool =
  let bounds = genericParameterBounds(tokens, nameToken, objectToken)
  if not bounds.valid or bounds.after >= objectToken or
      not tokens.tokenTextEquals(tokens[bounds.after], "="):
    return false
  var objectHeader = bounds.after + 1
  if objectHeader < objectToken and
      (tokens[objectHeader].isKeyword(kwRef) or tokens[objectHeader].isKeyword(kwPtr)):
    inc objectHeader
  if objectHeader != objectToken:
    return false
  if not bounds.present:
    return true
  var expectedName = true
  for index in bounds.first ..< bounds.past:
    let token = tokens[index]
    if tokens.tokenTextEquals(token, ","):
      if expectedName:
        return false
      expectedName = true
    elif validNameToken(tokens, index):
      if not expectedName:
        return false
      parameters.add uint32(index)
      expectedName = false
    else:
      return false
  if expectedName or parameters.len == 0:
    return false
  for parameterIndex, parameter in parameters:
    for previous in 0 ..< parameterIndex:
      if sameIdentifier(
        tokens.tokenText(tokens[int(parameters[previous])]),
        tokens.tokenText(tokens[int(parameter)]),
      ):
        return false
  true

proc addField(
    tokens: TokenStore,
    tokenIndex: int,
    fields: var seq[ObjectField],
    defaultVisibility = objectFieldPrivate,
): bool =
  if not validNameToken(tokens, tokenIndex):
    return false
  let token = tokens[tokenIndex]
  for field in fields:
    if sameIdentifier(
      tokens.tokenText(tokens[int(field.nameToken)]), tokens.tokenText(token)
    ):
      return false
  fields.add ObjectField(
    nameToken: uint32(tokenIndex),
    visibility:
      if tokenIndex + 1 < tokens.len and tokens[tokenIndex + 1].line == token.line and
          tokens.tokenTextEquals(tokens[tokenIndex + 1], "*"):
        objectFieldExported
      else:
        defaultVisibility,
  )
  true

proc parseFieldSegment(
    tokens: TokenStore,
    first, past: int,
    fields: var seq[ObjectField],
    defaultVisibility = objectFieldPrivate,
): bool =
  if first >= past:
    return true
  var colon = -1
  var depth = 0
  for index in first ..< past:
    if tokens.tokenTextEquals(tokens[index], "(") or
        tokens.tokenTextEquals(tokens[index], "[") or
        tokens.tokenTextEquals(tokens[index], "{"):
      inc depth
    elif tokens.tokenTextEquals(tokens[index], ")") or
        tokens.tokenTextEquals(tokens[index], "]") or
        tokens.tokenTextEquals(tokens[index], "}"):
      if depth == 0:
        return false
      dec depth
    elif depth == 0 and tokens.tokenTextEquals(tokens[index], ":"):
      colon = index
      break
  if colon <= first or colon + 1 >= past:
    return false

  var names: seq[int] = @[]
  var expectedName = true
  for index in first ..< colon:
    let token = tokens[index]
    if tokens.tokenTextEquals(token, ","):
      if expectedName:
        return false
      expectedName = true
    elif tokens.tokenTextEquals(token, "*"):
      if expectedName or index == first or tokens[index - 1].kind != tkIdentifier:
        return false
    elif validNameToken(tokens, index):
      if not expectedName:
        return false
      names.add index
      expectedName = false
    else:
      return false
  if names.len == 0 or expectedName:
    return false

  for nameToken in names:
    if not addField(tokens, nameToken, fields, defaultVisibility):
      return false
  true

proc parseFieldLine(
    tokens: TokenStore,
    first, past: int,
    fields: var seq[ObjectField],
    defaultVisibility = objectFieldPrivate,
): bool =
  var segment = first
  for index in first ..< past:
    if not tokens.tokenTextEquals(tokens[index], ";"):
      continue
    if not parseFieldSegment(tokens, segment, index, fields, defaultVisibility):
      return false
    segment = index + 1
  if segment < past and
      not parseFieldSegment(tokens, segment, past, fields, defaultVisibility):
    return false
  true

proc parseObjectFields(
    tokens: TokenStore, nameToken, objectToken, limit: int, fields: var seq[ObjectField]
): bool =
  var baseColumn = tokens[nameToken].column
  var declarationToken = nameToken - 1
  while declarationToken >= 0 and tokens[declarationToken].line == tokens[nameToken].line:
    if tokens[declarationToken].isKeyword(kwType):
      baseColumn = tokens[declarationToken].column
      break
    dec declarationToken
  let objectLine = tokens[objectToken].line
  var fieldIndent = -1
  var cursor = objectToken + 1
  while cursor < limit:
    let token = tokens[cursor]
    if tokens.tokenTextEquals(token, "{") or tokens.tokenTextEquals(token, "}"):
      return false
    if token.line <= objectLine:
      inc cursor
      continue
    if token.column <= baseColumn:
      return false
    if fieldIndent < 0:
      fieldIndent = token.column
    elif token.column < fieldIndent:
      return false
    if token.column == fieldIndent and (
      cursor == objectToken + 1 or tokens[cursor - 1].line != token.line or
      tokens.tokenTextEquals(tokens[cursor - 1], ";")
    ):
      var linePast = cursor + 1
      while linePast < limit and tokens[linePast].line == token.line:
        inc linePast
      if not parseFieldLine(tokens, cursor, linePast, fields):
        return false
      cursor = linePast
      continue
    inc cursor
  true

proc indexObject(tokens: TokenStore, symbol: SourceSymbol, types: var TypeIndex): bool =
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

proc tupleKeyword(tokens: TokenStore, nameToken, limit: int): int =
  if nameToken < 0 or nameToken >= limit:
    return -1
  let bounds = genericParameterBounds(tokens, nameToken, limit)
  if not bounds.valid or bounds.present or bounds.after >= limit or
      not tokens.tokenTextEquals(tokens[bounds.after], "=") or
      tokens[bounds.after].line != tokens[nameToken].line:
    return -1
  let tupleToken = bounds.after + 1
  if tupleToken >= limit or not tokens[tupleToken].isKeyword(kwTuple) or
      tokens[tupleToken].line != tokens[nameToken].line:
    return -1
  tupleToken

proc parseTupleFieldSegment(
    tokens: TokenStore, first, past: int, fields: var seq[ObjectField]
): bool =
  if first >= past:
    return false
  for index in first ..< past:
    if tokens[index].isKeyword(kwTuple):
      return false
  parseFieldSegment(tokens, first, past, fields, objectFieldExported)

proc parseTupleFields(
    tokens: TokenStore, tupleToken, limit: int, fields: var seq[ObjectField]
): bool =
  let opening = tupleToken + 1
  if opening >= limit or not tokens.tokenTextEquals(tokens[opening], "["):
    return false
  var segment = opening + 1
  var delimiters: seq[char] = @[]
  var closing = -1
  for cursor in segment ..< limit:
    let token = tokens[cursor]
    if tokens.tokenTextEquals(token, "(") or tokens.tokenTextEquals(token, "[") or
        tokens.tokenTextEquals(token, "{"):
      delimiters.add tokens.tokenTextChar(token, 0)
    elif tokens.tokenTextEquals(token, ")") or tokens.tokenTextEquals(token, "]") or
        tokens.tokenTextEquals(token, "}"):
      let delimiter = tokens.tokenTextChar(token, 0)
      if delimiters.len > 0:
        if not matchingDelimiter(delimiters[^1], delimiter):
          return false
        delimiters.setLen(delimiters.len - 1)
      elif delimiter == ']':
        if not parseTupleFieldSegment(tokens, segment, cursor, fields):
          return false
        closing = cursor
        break
      else:
        return false
    elif delimiters.len == 0 and tokens.tokenTextEquals(token, ","):
      if not parseTupleFieldSegment(tokens, segment, cursor, fields):
        return false
      segment = cursor + 1
  if closing < 0 or fields.len == 0:
    return false
  if closing + 1 < limit and tokens[closing + 1].line == tokens[tupleToken].line:
    return false
  true

proc parseTupleLiteralFieldSegment(
    tokens: TokenStore, first, past: int, fields: var seq[ObjectField]
): bool =
  if first + 2 >= past or not validNameToken(tokens, first) or
      not tokens.tokenTextEquals(tokens[first + 1], ":"):
    return false
  addField(tokens, first, fields)

proc parseTupleLiteralFields(
    tokens: TokenStore, first, past: int, fields: var seq[ObjectField]
): bool =
  if first < 0 or first + 2 >= past or past > tokens.len or
      not tokens.tokenTextEquals(tokens[first], "(") or
      not tokens.tokenTextEquals(tokens[past - 1], ")"):
    return false
  var delimiters: seq[char] = @[]
  var segment = first + 1
  for cursor in first + 1 ..< past - 1:
    let token = tokens[cursor]
    if tokens.tokenTextEquals(token, "(") or tokens.tokenTextEquals(token, "[") or
        tokens.tokenTextEquals(token, "{"):
      delimiters.add tokens.tokenTextChar(token, 0)
    elif tokens.tokenTextEquals(token, ")") or tokens.tokenTextEquals(token, "]") or
        tokens.tokenTextEquals(token, "}"):
      if delimiters.len == 0 or
          not matchingDelimiter(delimiters[^1], tokens.tokenTextChar(token, 0)):
        return false
      delimiters.setLen(delimiters.len - 1)
    elif delimiters.len == 0 and tokens.tokenTextEquals(token, ","):
      if not parseTupleLiteralFieldSegment(tokens, segment, cursor, fields):
        return false
      segment = cursor + 1
  if delimiters.len != 0 or
      not parseTupleLiteralFieldSegment(tokens, segment, past - 1, fields):
    return false
  fields.len > 0

proc indexTuple(tokens: TokenStore, symbol: SourceSymbol, types: var TypeIndex): bool =
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

proc enumKeyword(tokens: TokenStore, nameToken, limit: int): int =
  if nameToken < 0 or nameToken >= limit:
    return -1
  let bounds = genericParameterBounds(tokens, nameToken, limit)
  if not bounds.valid or bounds.present or bounds.after >= limit or
      not tokens.tokenTextEquals(tokens[bounds.after], "=") or
      tokens[bounds.after].line != tokens[nameToken].line:
    return -1
  let enumToken = bounds.after + 1
  if enumToken >= limit or not tokens[enumToken].isKeyword(kwEnum) or
      tokens[enumToken].line != tokens[nameToken].line:
    return -1
  enumToken

proc parseEnumFields(
    tokens: TokenStore, nameToken, enumToken, limit: int, fields: var seq[ObjectField]
): bool =
  var baseColumn = tokens[nameToken].column
  var declarationToken = nameToken - 1
  while declarationToken >= 0 and tokens[declarationToken].line == tokens[nameToken].line:
    if tokens[declarationToken].isKeyword(kwType):
      baseColumn = tokens[declarationToken].column
      break
    dec declarationToken
  var expectName = true
  var sawField = false
  var cursor = enumToken + 1
  while cursor < limit:
    let token = tokens[cursor]
    if token.line <= tokens[enumToken].line:
      inc cursor
      continue
    if token.column <= baseColumn:
      return sawField and not expectName
    if validNameToken(tokens, cursor):
      if not expectName:
        return false
      fields.add ObjectField(nameToken: uint32(cursor), visibility: objectFieldExported)
      expectName = false
      sawField = true
    elif tokens.tokenTextEquals(token, ","):
      if expectName:
        return false
      expectName = true
    else:
      return false
    inc cursor
  sawField and not expectName

proc indexEnum(tokens: TokenStore, symbol: SourceSymbol, types: var TypeIndex): bool =
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

proc simpleEnumDeclaration*(tokens: TokenStore, nameToken: uint32): bool =
  if nameToken == InvalidTypeToken or nameToken >= uint32(tokens.len):
    return false
  enumKeyword(tokens, int(nameToken), typeDeclarationEnd(tokens, int(nameToken))) >= 0

proc splitDeclaration(
    tokens: TokenStore, declaration: LexicalDeclaration
): tuple[colon, equals: int] =
  result = (-1, -1)
  var delimiters: seq[char] = @[]
  for index in int(declaration.firstToken) ..< int(declaration.pastToken):
    if tokens.tokenTextEquals(tokens[index], "(") or
        tokens.tokenTextEquals(tokens[index], "[") or
        tokens.tokenTextEquals(tokens[index], "{"):
      delimiters.add tokens.tokenTextChar(tokens[index], 0)
    elif tokens.tokenTextEquals(tokens[index], ")") or
        tokens.tokenTextEquals(tokens[index], "]") or
        tokens.tokenTextEquals(tokens[index], "}"):
      let delimiter = tokens.tokenTextChar(tokens[index], 0)
      if delimiters.len == 0 or not matchingDelimiter(delimiters[^1], delimiter):
        return
      delimiters.setLen(delimiters.len - 1)
    elif delimiters.len == 0:
      if tokens.tokenTextEquals(tokens[index], ":") and result.colon < 0:
        result.colon = index
      elif tokens.tokenTextEquals(tokens[index], "=") and result.equals < 0:
        result.equals = index

proc nominalTypeToken(tokens: TokenStore, first, past: int): uint32 =
  var cursor = first
  if cursor < past and tokens[cursor].isKeyword(kwPtr):
    inc cursor
  if cursor >= past or not validNameToken(tokens, cursor):
    return InvalidTypeToken
  if cursor + 1 == past:
    return uint32(cursor)
  if cursor + 3 == past and tokens.tokenTextEquals(tokens[cursor + 1], ".") and
      validNameToken(tokens, cursor + 2):
    return uint32(cursor + 2)
  InvalidTypeToken

proc directCallInfo(tokens: TokenStore, first, past: int): LocalTypeInfo =
  if first >= past or not validNameToken(tokens, first):
    return
  var nameToken = first
  if first + 2 < past and tokens.tokenTextEquals(tokens[first + 1], ".") and
      validNameToken(tokens, first + 2):
    nameToken = first + 2
  if nameToken + 1 >= past or not tokens.tokenTextEquals(tokens[nameToken + 1], "("):
    return
  var delimiters: seq[char] = @[]
  for index in nameToken + 1 ..< past:
    if tokens.tokenTextEquals(tokens[index], "(") or
        tokens.tokenTextEquals(tokens[index], "[") or
        tokens.tokenTextEquals(tokens[index], "{"):
      delimiters.add tokens.tokenTextChar(tokens[index], 0)
    elif tokens.tokenTextEquals(tokens[index], ")") or
        tokens.tokenTextEquals(tokens[index], "]") or
        tokens.tokenTextEquals(tokens[index], "}"):
      let delimiter = tokens.tokenTextChar(tokens[index], 0)
      if delimiters.len == 0 or not matchingDelimiter(delimiters[^1], delimiter):
        return
      delimiters.setLen(delimiters.len - 1)
      if delimiters.len == 0 and index + 1 != past:
        return
  if delimiters.len != 0:
    return
  result.kind = typeNamed
  result.state = typeStateUnresolved
  result.form = localTypeFormCall
  result.typeToken = uint32(nameToken)
  result.firstToken = uint32(first)
  result.pastToken = uint32(nameToken + 1)

proc typeUseFor(tokens: TokenStore, declaration: LexicalDeclaration): uint32 =
  let split = splitDeclaration(tokens, declaration)
  if split.equals >= 0:
    let call = directCallInfo(tokens, split.equals + 1, int(declaration.pastToken))
    if call.form == localTypeFormCall:
      return call.typeToken
  InvalidTypeToken

proc numericSuffix(kind: TypeKind): string {.inline.} =
  case kind
  of typeFloat: "f"
  of typeFloat32: "f32"
  of typeFloat64: "f64"
  of typeFloat128: "f128"
  of typeInt8: "i8"
  of typeInt16: "i16"
  of typeInt32: "i32"
  of typeInt64: "i64"
  of typeUInt: "u"
  of typeUInt8: "u8"
  of typeUInt16: "u16"
  of typeUInt32: "u32"
  of typeUInt64: "u64"
  else: ""

proc tokenTextEqualsAt(
    tokens: TokenStore, token: Token, first: int, wanted: string
): bool {.inline.} =
  if first < 0 or first + wanted.len > tokens.tokenTextLen(token):
    return false
  for index in 0 ..< wanted.len:
    if tokens.tokenTextChar(token, first + index) != wanted[index]:
      return false
  true

proc numericLiteralKind(tokens: TokenStore, token: Token): TypeKind =
  let length = tokens.tokenTextLen(token)
  let based =
    length >= 2 and tokens.tokenTextChar(token, 0) == '0' and
    tokens.tokenTextChar(token, 1) in {'b', 'B', 'o', 'O', 'x', 'X'}
  for kind in primitiveTypeKinds:
    let suffix = kind.numericSuffix
    if suffix.len == 0 or suffix.len > length:
      continue
    let suffixFirst = length - suffix.len
    if not tokens.tokenTextEqualsAt(token, suffixFirst, suffix):
      continue
    let quoted =
      suffixFirst > 0 and tokens.tokenTextChar(token, suffixFirst - 1) == '\''
    if quoted or not based:
      return kind
  if based:
    return typeInt
  for index in 0 ..< length:
    if tokens.tokenTextChar(token, index) in {'.', 'e', 'E'}:
      return typeFloat
  typeInt

proc directLiteralKind(tokens: TokenStore, first, past: int): TypeKind =
  if first < 0 or first >= past or past > tokens.len:
    return typeUnknown
  if past == first + 1:
    let token = tokens[first]
    if token.kind == tkIdentifier:
      if tokens.tokenTextEquals(token, "true") or tokens.tokenTextEquals(token, "false"):
        return typeBool
    elif token.kind == tkString and isClosedString(token):
      if tokens.tokenTextChar(token, 0) == '"':
        if tokens.tokenTextLen(token) >= 3 and tokens.tokenTextChar(token, 1) == '"' and
            tokens.tokenTextChar(token, 2) == '"':
          return typeUnknown
        return typeString
      if tokens.tokenTextChar(token, 0) == char(39) and tokens.tokenTextLen(token) >= 3:
        return typeChar
    elif token.kind == tkNumber:
      return numericLiteralKind(tokens, token)
    return typeUnknown
  typeUnknown

proc primitiveTypeKind(tokens: TokenStore, index: int): TypeKind =
  if not validNameToken(tokens, index):
    return typeUnknown
  for kind in primitiveTypeKinds:
    if tokens.tokenTextEquals(tokens[index], kind.primitiveTypeName):
      return kind
  typeUnknown

proc sequenceAnnotationDescriptor(
    tokens: TokenStore, first, past: int
): TypeDescriptor =
  result.kind = typeUnknown
  result.nameToken = InvalidTypeToken
  result.baseKind = typeUnknown
  result.baseNameToken = InvalidTypeToken
  result.extent = 0'u32
  if first < 0 or past != first + 4 or past > tokens.len or
      not tokens.tokenTextEquals(tokens[first], "seq") or
      not tokens.tokenTextEquals(tokens[first + 1], "[") or
      not tokens.tokenTextEquals(tokens[past - 1], "]"):
    return
  let elementKind = primitiveTypeKind(tokens, first + 2)
  if elementKind.isPrimitiveType:
    result.kind = typeSeq
    result.baseKind = elementKind
    return
  if not validNameToken(tokens, first + 2):
    return
  result.kind = typeSeq
  result.baseKind = typeNamed
  result.baseNameToken = uint32(first + 2)

proc arrayAnnotationDescriptor(tokens: TokenStore, first, past: int): TypeDescriptor =
  result.kind = typeUnknown
  result.nameToken = InvalidTypeToken
  result.baseKind = typeUnknown
  result.baseNameToken = InvalidTypeToken
  result.extent = 0'u32
  if first < 0 or first + 1 >= past or past > tokens.len or
      not tokens.tokenTextEquals(tokens[first], "array") or
      not tokens.tokenTextEquals(tokens[first + 1], "[") or
      not tokens.tokenTextEquals(tokens[past - 1], "]"):
    return
  var comma = -1
  for index in first + 2 ..< past - 1:
    if tokens.tokenTextEquals(tokens[index], ","):
      if comma >= 0:
        return
      comma = index
  if comma < first + 3 or comma + 2 != past - 1:
    return
  if comma != first + 3 or tokens[first + 2].kind != tkNumber:
    return
  var extent = 0'u32
  let extentToken = tokens[first + 2]
  for index in 0 ..< tokens.tokenTextLen(extentToken):
    let character = tokens.tokenTextChar(extentToken, index)
    if character == '_':
      continue
    if character < '0' or character > '9':
      return
    let digit = uint32(ord(character) - ord('0'))
    if extent > (high(uint32) - digit) div 10'u32:
      return
    extent = extent * 10'u32 + digit
  let baseKind = primitiveTypeKind(tokens, comma + 1)
  result.kind = typeArray
  if baseKind != typeUnknown:
    result.baseKind = baseKind
  elif validNameToken(tokens, comma + 1):
    result.baseKind = typeNamed
    result.baseNameToken = uint32(comma + 1)
  else:
    result.kind = typeUnknown
    return
  result.extent = extent

proc genericArgument(
    tokens: TokenStore, first, past: int, kind: var TypeKind, nameToken: var uint32
): bool =
  if first >= past:
    return false
  kind = primitiveTypeKind(tokens, first)
  if kind != typeUnknown:
    return first + 1 == past
  nameToken = nominalTypeToken(tokens, first, past)
  nameToken != InvalidTypeToken

proc genericAnnotationDescriptor(tokens: TokenStore, first, past: int): TypeDescriptor =
  result.kind = typeUnknown
  result.nameToken = InvalidTypeToken
  result.baseKind = typeUnknown
  result.baseNameToken = InvalidTypeToken
  result.extent = 0'u32
  result.genericArguments = @[]
  if first < 0 or first + 3 >= past or past > tokens.len or
      not tokens.tokenTextEquals(tokens[past - 1], "]"):
    return
  var opening = -1
  for index in first ..< past - 1:
    if tokens.tokenTextEquals(tokens[index], "["):
      if opening >= 0:
        return
      opening = index
  if opening <= first or opening + 1 >= past - 1:
    return
  let nameToken = nominalTypeToken(tokens, first, opening)
  if nameToken == InvalidTypeToken:
    return
  let argumentFirst = opening + 1
  let argumentPast = past - 1
  var segmentFirst = argumentFirst
  var argumentKind = typeUnknown
  var argumentName = InvalidTypeToken
  var arguments = 0
  for index in argumentFirst ..< argumentPast:
    if not tokens.tokenTextEquals(tokens[index], ","):
      continue
    var segmentKind = typeUnknown
    var segmentName = InvalidTypeToken
    if not genericArgument(tokens, segmentFirst, index, segmentKind, segmentName):
      return
    if arguments == 0:
      argumentKind = segmentKind
      argumentName = segmentName
    result.genericArguments.add GenericArgumentDescriptor(
      kind: segmentKind, nameToken: segmentName
    )
    inc arguments
    segmentFirst = index + 1
  var segmentKind = typeUnknown
  var segmentName = InvalidTypeToken
  if not genericArgument(tokens, segmentFirst, argumentPast, segmentKind, segmentName):
    return
  if arguments == 0:
    argumentKind = segmentKind
    argumentName = segmentName
  result.genericArguments.add GenericArgumentDescriptor(
    kind: segmentKind, nameToken: segmentName
  )
  result.kind = typeGenericInstance
  result.nameToken = nameToken
  result.baseKind = argumentKind
  result.baseNameToken = argumentName

proc genericArgumentTypeId(
    types: TypeIndex, argument: GenericArgumentDescriptor
): TypeId {.inline.} =
  if argument.kind.isPrimitiveType:
    types.typeIdFor(argument.kind)
  elif argument.kind == typeNamed:
    types.typeIdFor(typeNamed, argument.nameToken)
  else:
    InvalidTypeId

proc internGenericArgumentTypeId(
    types: var TypeIndex, argument: GenericArgumentDescriptor
): TypeId {.inline.} =
  if argument.kind.isPrimitiveType:
    types.internType(argument.kind)
  elif argument.kind == typeNamed:
    types.internType(typeNamed, argument.nameToken)
  else:
    InvalidTypeId

proc genericArgumentTypeIds(types: TypeIndex, descriptor: TypeDescriptor): seq[TypeId] =
  for argument in descriptor.genericArguments:
    let typeId = types.genericArgumentTypeId(argument)
    if not typeId.valid:
      return @[]
    result.add typeId

proc internGenericArgumentTypeIds(
    types: var TypeIndex, descriptor: TypeDescriptor
): seq[TypeId] =
  for argument in descriptor.genericArguments:
    let typeId = types.internGenericArgumentTypeId(argument)
    if not typeId.valid:
      return @[]
    result.add typeId

proc annotationDescriptor(tokens: TokenStore, first, past: int): TypeDescriptor =
  result.kind = typeUnknown
  result.nameToken = InvalidTypeToken
  result.baseKind = typeUnknown
  result.baseNameToken = InvalidTypeToken
  result.extent = 0'u32
  let arrayDescriptor = arrayAnnotationDescriptor(tokens, first, past)
  if arrayDescriptor.kind != typeUnknown:
    return arrayDescriptor
  let sequenceDescriptor = sequenceAnnotationDescriptor(tokens, first, past)
  if sequenceDescriptor.kind != typeUnknown:
    return sequenceDescriptor
  let genericDescriptor = genericAnnotationDescriptor(tokens, first, past)
  if genericDescriptor.kind != typeUnknown:
    return genericDescriptor
  if first + 1 == past:
    let primitiveKind = primitiveTypeKind(tokens, first)
    if primitiveKind != typeUnknown:
      result.kind = primitiveKind
      return
  var cursor = first
  let isReference = cursor < past and tokens[cursor].isKeyword(kwRef)
  if isReference:
    inc cursor
    if cursor >= past or tokens[cursor].isKeyword(kwRef) or
        tokens[cursor].isKeyword(kwPtr):
      return
  let typeToken = nominalTypeToken(tokens, cursor, past)
  if typeToken == InvalidTypeToken:
    return
  if isReference:
    result.kind = typeRef
    result.baseKind = typeNamed
    result.baseNameToken = typeToken
  else:
    result.kind = typeNamed
    result.nameToken = typeToken

proc supportedGenericInstance*(types: TypeIndex, info: LocalTypeInfo): bool =
  if info.kind != typeGenericInstance or info.state != typeStateResolved or
      info.form != localTypeFormAnnotation or info.typeToken == InvalidTypeToken:
    return false
  if types.typeKind(info.typeId) != typeGenericInstance:
    return false
  let count = types.genericArgumentCount(info.typeId)
  if count == 0:
    return false
  for index in 0 ..< count:
    let argument = types.genericArgumentType(info.typeId, index)
    let kind = types.typeKind(argument)
    if not kind.isPrimitiveType and kind != typeNamed:
      return false
    if kind == typeNamed and types.typeNameToken(argument) == InvalidTypeToken:
      return false
  true

proc sequenceLiteralStart*(tokens: TokenStore, index: int): bool {.inline.} =
  index >= 0 and index + 1 < tokens.len and tokens[index].kind == tkPunctuation and
    tokens[index + 1].kind == tkPunctuation and
    tokens.tokenTextEquals(tokens[index], "@") and
    tokens.tokenTextEquals(tokens[index + 1], "[")

proc sameTupleFieldShape(
    tokens: TokenStore, left, right: openArray[ObjectField]
): bool =
  if left.len == 0 or left.len != right.len:
    return false
  for fieldIndex, leftField in left:
    if not sameIdentifier(
      tokens.tokenText(tokens[int(leftField.nameToken)]),
      tokens.tokenText(tokens[int(right[fieldIndex].nameToken)]),
    ):
      return false
    for previous in 0 ..< fieldIndex:
      if sameIdentifier(
        tokens.tokenText(tokens[int(left[fieldIndex].nameToken)]),
        tokens.tokenText(tokens[int(left[previous].nameToken)]),
      ):
        return false
  true

proc sequenceLiteralTupleFields(
    tokens: TokenStore, first, past: int, fields: var seq[ObjectField]
): bool =
  if first < 0 or first + 3 > past or past > tokens.len or
      not tokens.sequenceLiteralStart(first) or
      not tokens.tokenTextEquals(tokens[past - 1], "]"):
    return false
  var elementFirst = first + 2
  if elementFirst >= past - 1:
    return false
  while elementFirst < past - 1:
    var elementPast = elementFirst
    var delimiters: seq[char] = @[]
    while elementPast < past - 1:
      let token = tokens[elementPast]
      if token.kind == tkPunctuation and tokens.tokenTextLen(token) == 1:
        let value = tokens.tokenTextChar(token, 0)
        if isOpeningDelimiter(value):
          delimiters.add value
        elif isClosingDelimiter(value):
          if delimiters.len == 0 or not matchingDelimiter(delimiters[^1], value):
            return false
          delimiters.setLen(delimiters.len - 1)
        elif delimiters.len == 0 and value == ',':
          break
      inc elementPast
    if delimiters.len != 0 or elementPast == elementFirst:
      return false
    var elementFields: seq[ObjectField] = @[]
    if not parseTupleLiteralFields(tokens, elementFirst, elementPast, elementFields):
      return false
    if fields.len == 0:
      fields = elementFields
    elif not sameTupleFieldShape(tokens, fields, elementFields):
      return false
    if elementPast == past - 1:
      return true
    elementFirst = elementPast + 1
    if elementFirst >= past - 1:
      return false
  false

proc sequenceLiteralElementKind(tokens: TokenStore, first, past: int): TypeKind =
  if first < 0 or first + 3 > past or past > tokens.len or
      not tokens.sequenceLiteralStart(first) or
      not tokens.tokenTextEquals(tokens[past - 1], "]"):
    return typeUnknown
  var elementFirst = first + 2
  if elementFirst >= past - 1:
    return typeUnknown
  var resultKind = typeUnknown
  while elementFirst < past - 1:
    var elementPast = elementFirst
    while elementPast < past - 1 and not tokens.tokenTextEquals(
      tokens[elementPast], ","
    )
    :
      inc elementPast
    let elementKind = directLiteralKind(tokens, elementFirst, elementPast)
    if elementKind == typeUnknown:
      return typeUnknown
    if resultKind == typeUnknown:
      resultKind = elementKind
    elif resultKind != elementKind:
      return typeUnknown
    if elementPast == past - 1:
      break
    elementFirst = elementPast + 1
    if elementFirst >= past - 1:
      return typeUnknown
  resultKind

proc declarationTypeDescriptor(
    tokens: TokenStore, declaration: LexicalDeclaration
): TypeDescriptor =
  result.kind = typeUnknown
  result.nameToken = InvalidTypeToken
  result.baseKind = typeUnknown
  result.baseNameToken = InvalidTypeToken
  result.extent = 0'u32
  let split = splitDeclaration(tokens, declaration)
  if split.colon >= 0:
    let past =
      if split.equals > split.colon:
        split.equals
      else:
        int(declaration.pastToken)
    return annotationDescriptor(tokens, split.colon + 1, past)
  if split.equals < 0:
    return
  let typeToken = typeUseFor(tokens, declaration)
  if typeToken != InvalidTypeToken:
    result.kind = typeNamed
    result.nameToken = typeToken
    return
  if split.equals >= 0:
    let first = split.equals + 1
    let past = int(declaration.pastToken)
    var tupleFields: seq[ObjectField] = @[]
    if parseTupleLiteralFields(tokens, first, past, tupleFields):
      result.kind = typeNamed
      result.nameToken = declaration.nameToken
      return
    if sequenceLiteralTupleFields(tokens, first, past, tupleFields):
      result.kind = typeSeq
      result.baseKind = typeNamed
      result.baseNameToken = declaration.nameToken
      return
    result.baseKind = sequenceLiteralElementKind(tokens, first, past)
    if result.baseKind != typeUnknown:
      result.kind = typeSeq
    else:
      result.kind = directLiteralKind(tokens, first, past)

proc descriptorTypeId(types: TypeIndex, descriptor: TypeDescriptor): TypeId =
  let genericArguments = types.genericArgumentTypeIds(descriptor)
  let baseType =
    case descriptor.kind
    of typeSeq:
      if descriptor.baseKind == typeNamed:
        types.typeIdFor(typeNamed, descriptor.baseNameToken)
      else:
        types.typeIdFor(descriptor.baseKind)
    of typeRef:
      types.typeIdFor(typeNamed, descriptor.baseNameToken)
    of typeArray:
      if descriptor.baseKind == typeNamed:
        types.typeIdFor(typeNamed, descriptor.baseNameToken)
      else:
        types.typeIdFor(descriptor.baseKind)
    of typeGenericInstance:
      if genericArguments.len > 0:
        genericArguments[0]
      else:
        InvalidTypeId
    else:
      InvalidTypeId
  types.typeIdFor(
    descriptor.kind, descriptor.nameToken, baseType, descriptor.extent, genericArguments
  )

proc internDescriptor(types: var TypeIndex, descriptor: TypeDescriptor): TypeId =
  let genericArguments = types.internGenericArgumentTypeIds(descriptor)
  let baseType =
    case descriptor.kind
    of typeSeq:
      if descriptor.baseKind == typeNamed:
        types.internType(typeNamed, descriptor.baseNameToken)
      else:
        types.internType(descriptor.baseKind)
    of typeRef:
      types.internType(typeNamed, descriptor.baseNameToken)
    of typeArray:
      if descriptor.baseKind == typeNamed:
        types.internType(typeNamed, descriptor.baseNameToken)
      else:
        types.internType(descriptor.baseKind)
    of typeGenericInstance:
      if genericArguments.len > 0:
        genericArguments[0]
      else:
        InvalidTypeId
    else:
      InvalidTypeId
  types.internType(
    descriptor.kind, descriptor.nameToken, baseType, descriptor.extent, genericArguments
  )

proc localTypeAt*(
    types: TypeIndex, tokens: TokenStore, scopes: ScopeIndex, declarationToken: uint32
): LocalTypeInfo =
  if types.localTypeIds.len != scopes.declarations.len:
    return
  let declarationOrdinal = scopes.declarationOrdinalAt(declarationToken)
  if declarationOrdinal < 0 or declarationOrdinal >= scopes.declarations.len:
    return
  let declaration = scopes.declarations[declarationOrdinal]
  if declaration.pastToken > uint32(tokens.len):
    return
  let split = splitDeclaration(tokens, declaration)
  let descriptor = declarationTypeDescriptor(tokens, declaration)
  let expected = types.descriptorTypeId(descriptor)
  if expected == InvalidTypeId or types.localTypeIds[declarationOrdinal] != expected:
    return
  if split.colon >= 0:
    let past =
      if split.equals > split.colon:
        split.equals
      else:
        int(declaration.pastToken)
    if descriptor.kind == typeUnknown:
      return
    result.kind = descriptor.kind
    result.state = typeStateResolved
    result.form = localTypeFormAnnotation
    result.typeId = expected
    result.typeToken =
      if descriptor.kind == typeNamed:
        descriptor.nameToken
      elif descriptor.kind == typeRef:
        descriptor.baseNameToken
      elif descriptor.kind == typeGenericInstance:
        descriptor.nameToken
      elif descriptor.kind == typeSeq and descriptor.baseKind == typeNamed:
        descriptor.baseNameToken
      elif descriptor.kind == typeArray and descriptor.baseKind == typeNamed:
        descriptor.baseNameToken
      else:
        InvalidTypeToken
    result.firstToken = uint32(split.colon + 1)
    result.pastToken = uint32(past)
    return
  if split.equals < 0:
    return

  var call = directCallInfo(tokens, split.equals + 1, int(declaration.pastToken))
  if call.form == localTypeFormCall:
    call.typeId = expected
    return call

  result.kind = descriptor.kind
  if result.kind != typeUnknown:
    result.state = typeStateResolved
    result.form = localTypeFormLiteral
    result.typeId = expected
    result.typeToken =
      if descriptor.kind == typeNamed and descriptor.nameToken != declaration.nameToken:
        descriptor.nameToken
      elif descriptor.kind in {typeSeq, typeArray} and descriptor.baseKind == typeNamed:
        descriptor.baseNameToken
      else:
        InvalidTypeToken
    result.firstToken = uint32(split.equals + 1)
    result.pastToken = declaration.pastToken

proc routineReturnSpan(
    tokens: TokenStore, symbol: SourceSymbol
): tuple[descriptor: TypeDescriptor, first, past: int] =
  result.descriptor.kind = typeUnknown
  result.descriptor.nameToken = InvalidTypeToken
  result.descriptor.baseKind = typeUnknown
  result.descriptor.baseNameToken = InvalidTypeToken
  result.descriptor.extent = 0'u32
  result.first = -1
  result.past = -1
  if symbol.kind notin {symbolProc, symbolFunc} or symbol.nameToken >= uint32(
    tokens.len
  ):
    return
  let nameToken = int(symbol.nameToken)
  if nameToken <= 0 or
      not tokens[nameToken - 1].isKeyword(kwProc) and
      not tokens[nameToken - 1].isKeyword(kwFunc):
    return
  var opening = nameToken + 1
  if opening < tokens.len and tokens.tokenTextEquals(tokens[opening], "*"):
    inc opening
  if opening >= tokens.len or not tokens.tokenTextEquals(tokens[opening], "("):
    return

  var delimiters: seq[char] = @[]
  var closing = -1
  for index in opening ..< tokens.len:
    if tokens.tokenTextLen(tokens[index]) == 1 and
        isOpeningDelimiter(tokens.tokenTextChar(tokens[index], 0)):
      delimiters.add tokens.tokenTextChar(tokens[index], 0)
    elif tokens.tokenTextLen(tokens[index]) == 1 and
        isClosingDelimiter(tokens.tokenTextChar(tokens[index], 0)):
      let delimiter = tokens.tokenTextChar(tokens[index], 0)
      if delimiters.len == 0 or not matchingDelimiter(delimiters[^1], delimiter):
        return
      delimiters.setLen(delimiters.len - 1)
      if delimiters.len == 0:
        closing = index
        break
  if closing < 0 or closing + 1 >= tokens.len or
      not tokens.tokenTextEquals(tokens[closing + 1], ":"):
    return

  let first = closing + 2
  var past = first
  while past < tokens.len and not tokens.tokenTextEquals(tokens[past], "="):
    inc past
  if first >= past:
    return
  let descriptor = annotationDescriptor(tokens, first, past)
  if descriptor.kind == typeUnknown:
    return
  result.descriptor = descriptor
  result.first = first
  result.past = past

proc routineReturnAt*(
    types: TypeIndex,
    tokens: TokenStore,
    symbols: openArray[SourceSymbol],
    symbolOrdinal: int,
): LocalTypeInfo =
  if types.routineReturnTypeIds.len != symbols.len or symbolOrdinal < 0 or
      symbolOrdinal >= symbols.len:
    return
  if not types.routineReturnTypeIds[symbolOrdinal].valid:
    return
  let span = routineReturnSpan(tokens, symbols[symbolOrdinal])
  let expected = types.descriptorTypeId(span.descriptor)
  if expected == InvalidTypeId or expected != types.routineReturnTypeIds[symbolOrdinal]:
    return
  result.kind = span.descriptor.kind
  result.state = typeStateResolved
  result.form = localTypeFormAnnotation
  result.typeId = expected
  result.typeToken =
    if span.descriptor.kind == typeNamed:
      span.descriptor.nameToken
    elif span.descriptor.kind == typeRef:
      span.descriptor.baseNameToken
    elif span.descriptor.kind == typeGenericInstance:
      span.descriptor.nameToken
    elif span.descriptor.kind == typeSeq and span.descriptor.baseKind == typeNamed:
      span.descriptor.baseNameToken
    else:
      InvalidTypeToken
  result.firstToken = uint32(span.first)
  result.pastToken = uint32(span.past)

proc indexUfcsProcedures(
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

proc objectOrdinal*(index: TypeIndex, declarationToken: uint32): int {.inline.} =
  var first = 0
  var past = index.objects.len
  while first < past:
    let middle = (first + past) div 2
    let candidate = index.objects[middle].declarationToken
    if candidate < declarationToken:
      first = middle + 1
    elif candidate > declarationToken:
      past = middle
    else:
      return middle
  -1

proc localTupleObjectOrdinal*(
    index: TypeIndex, declarationToken: uint32
): int {.inline.} =
  var first = 0
  var past = index.localTupleObjects.len
  while first < past:
    let middle = (first + past) div 2
    let candidate = index.localTupleObjects[middle].declarationToken
    if candidate < declarationToken:
      first = middle + 1
    elif candidate > declarationToken:
      past = middle
    else:
      return middle
  -1

proc objectFieldOrdinal*(index: TypeIndex, nameToken: uint32): int {.inline.} =
  var first = 0
  var past = index.fields.len
  while first < past:
    let middle = (first + past) div 2
    let candidate = index.fields[middle].nameToken
    if candidate < nameToken:
      first = middle + 1
    elif candidate > nameToken:
      past = middle
    else:
      return middle
  -1

proc objectFieldExportMarker*(index: TypeIndex, tokenIndex: uint32): bool {.inline.} =
  if tokenIndex == 0:
    return false
  let ordinal = index.objectFieldOrdinal(tokenIndex - 1'u32)
  ordinal >= 0 and index.fields[ordinal].visibility == objectFieldExported

proc objectOrdinalForType*(
    index: TypeIndex,
    tokens: TokenStore,
    symbols: openArray[SourceSymbol],
    typeToken: uint32,
): int =
  if typeToken == InvalidTypeToken or not validNameToken(tokens, int(typeToken)):
    return -1
  let wanted = identifierKey(tokens, tokens[int(typeToken)])
  var found = -1
  var matches = 0
  for symbol in symbols:
    if symbol.kind != symbolType or symbol.nameToken >= uint32(tokens.len):
      continue
    if identifierKey(tokens, tokens[int(symbol.nameToken)]) != wanted:
      continue
    inc matches
    let ordinal = index.objectOrdinal(symbol.nameToken)
    if ordinal < 0:
      return -1
    found = ordinal
  if matches == 1: found else: -1

proc validateTypeIndex*(
    index: TypeIndex,
    tokens: TokenStore,
    symbols: openArray[SourceSymbol],
    scopes: ScopeIndex,
): bool =
  if index.localTypeIds.len != scopes.declarations.len or
      index.routineReturnTypeIds.len != symbols.len:
    return false
  for recordIndex, record in index.records:
    if record.firstArgument > record.pastArgument or
        record.pastArgument > uint32(index.genericArgumentTypeIds.len) or
        record.kind != typeGenericInstance and
        record.firstArgument != record.pastArgument:
      return false
    case record.kind
    of typeUnknown:
      return false
    of typeNamed:
      if record.nameToken == InvalidTypeToken or record.baseType.valid or
          record.extent != 0'u32 or record.nameToken >= uint32(tokens.len) or
          not validNameToken(tokens, int(record.nameToken)):
        return false
    of typeSeq:
      if record.nameToken != InvalidTypeToken or not record.baseType.valid or
          record.extent != 0'u32 or uint32(record.baseType) > uint32(recordIndex):
        return false
    of typeRef:
      if record.nameToken != InvalidTypeToken or not record.baseType.valid or
          record.extent != 0'u32 or uint32(record.baseType) > uint32(recordIndex) or
          index.typeKind(record.baseType) != typeNamed:
        return false
    of typeArray:
      if record.nameToken != InvalidTypeToken or not record.baseType.valid or
          uint32(record.baseType) > uint32(recordIndex) or (
        not index.typeKind(record.baseType).isPrimitiveType and
        index.typeKind(record.baseType) != typeNamed
      ):
        return false
    of typeGenericInstance:
      if record.nameToken == InvalidTypeToken or not record.baseType.valid or
          uint32(record.baseType) > uint32(recordIndex) or record.extent != 0'u32 or
          record.firstArgument == record.pastArgument or
          record.baseType != index.genericArgumentTypeIds[int(record.firstArgument)] or
          record.nameToken >= uint32(tokens.len) or
          not validNameToken(tokens, int(record.nameToken)) or
          not (
            index.typeKind(record.baseType).isPrimitiveType or
            index.typeKind(record.baseType) == typeNamed
          ):
        return false
      for argumentIndex in record.firstArgument ..< record.pastArgument:
        let argument = index.genericArgumentTypeIds[int(argumentIndex)]
        let argumentKind = index.typeKind(argument)
        if not argument.valid or uint32(argument) > uint32(recordIndex) or
            not argumentKind.isPrimitiveType and argumentKind != typeNamed:
          return false
    else:
      if record.nameToken != InvalidTypeToken or record.baseType.valid or
          record.extent != 0'u32:
        return false
    for previous in 0 ..< recordIndex:
      if index.records[previous].kind == record.kind and
          index.records[previous].nameToken == record.nameToken and
          index.records[previous].baseType == record.baseType and
          index.records[previous].extent == record.extent and
          index.sameGenericRecordArguments(index.records[previous], record):
        return false
  var previousObject = high(uint32)
  for objectType in index.objects:
    if objectType.declarationToken >= uint32(tokens.len) or (
      previousObject != high(uint32) and objectType.declarationToken <= previousObject
    ) or objectType.firstField > objectType.pastField or
        objectType.pastField > uint32(index.fields.len) or
        objectType.firstGenericParameter > objectType.pastGenericParameter or
        objectType.pastGenericParameter > uint32(index.genericParameterTokens.len):
      return false
    previousObject = objectType.declarationToken
    var symbolMatches = 0
    for symbol in symbols:
      if symbol.kind == symbolType and symbol.nameToken == objectType.declarationToken:
        inc symbolMatches
    if symbolMatches != 1:
      return false
    let limit = typeDeclarationEnd(tokens, int(objectType.declarationToken))
    if limit < 0:
      return false
    if objectType.pastGenericParameter > objectType.firstGenericParameter:
      for parameterIndex in objectType.firstGenericParameter ..<
          objectType.pastGenericParameter:
        let parameterToken = index.genericParameterTokens[int(parameterIndex)]
        if parameterToken <= objectType.declarationToken or
            parameterToken >= uint32(limit) or
            not validNameToken(tokens, int(parameterToken)):
          return false
        for previous in objectType.firstGenericParameter ..< parameterIndex:
          if sameIdentifier(
            tokens.tokenText(tokens[int(index.genericParameterTokens[int(previous)])]),
            tokens.tokenText(tokens[int(parameterToken)]),
          ):
            return false
    if objectType.pastField > objectType.firstField:
      for fieldIndex in objectType.firstField ..< objectType.pastField:
        let fieldToken = index.fields[int(fieldIndex)].nameToken
        if fieldToken <= objectType.declarationToken or fieldToken >= uint32(limit) or
            not validNameToken(tokens, int(fieldToken)):
          return false
        for previous in objectType.firstField ..< fieldIndex:
          if sameIdentifier(
            tokens.tokenText(tokens[int(index.fields[int(previous)].nameToken)]),
            tokens.tokenText(tokens[int(fieldToken)]),
          ):
            return false
  var previousLocalTuple = high(uint32)
  for objectType in index.localTupleObjects:
    if objectType.declarationToken >= uint32(tokens.len) or (
      previousLocalTuple != high(uint32) and
      objectType.declarationToken <= previousLocalTuple
    ) or objectType.firstField > objectType.pastField or
        objectType.pastField > uint32(index.localTupleFields.len):
      return false
    let declarationOrdinal = scopes.declarationOrdinalAt(objectType.declarationToken)
    if declarationOrdinal < 0 or declarationOrdinal >= scopes.declarations.len:
      return false
    let declaration = scopes.declarations[declarationOrdinal]
    let descriptor = declarationTypeDescriptor(tokens, declaration)
    if not (
      descriptor.kind == typeNamed and descriptor.nameToken == declaration.nameToken
    ) and
        not (
          descriptor.kind == typeSeq and descriptor.baseKind == typeNamed and
          descriptor.baseNameToken == declaration.nameToken
        ):
      return false
    for fieldIndex in objectType.firstField ..< objectType.pastField:
      let fieldToken = index.localTupleFields[int(fieldIndex)].nameToken
      if fieldToken <= objectType.declarationToken or fieldToken >= declaration.pastToken or
          not validNameToken(tokens, int(fieldToken)):
        return false
      for previous in objectType.firstField ..< fieldIndex:
        if sameIdentifier(
          tokens.tokenText(tokens[int(index.localTupleFields[int(previous)].nameToken)]),
          tokens.tokenText(tokens[int(fieldToken)]),
        ):
          return false
    previousLocalTuple = objectType.declarationToken
  for declarationIndex, typeId in index.localTypeIds:
    if not typeId.valid:
      continue
    let declaration = scopes.declarations[declarationIndex]
    let descriptor = declarationTypeDescriptor(tokens, declaration)
    if index.descriptorTypeId(descriptor) != typeId:
      return false
    let typeToken =
      case descriptor.kind
      of typeNamed, typeGenericInstance: descriptor.nameToken
      of typeRef: descriptor.baseNameToken
      else: InvalidTypeToken
    if descriptor.kind notin {typeNamed, typeRef, typeGenericInstance}:
      continue
    if descriptor.kind == typeNamed and descriptor.nameToken == declaration.nameToken and
        index.localTupleObjectOrdinal(declaration.nameToken) < 0:
      return false
    if typeToken < declaration.firstToken or typeToken >= declaration.pastToken or
        not validNameToken(tokens, int(typeToken)):
      return false
  for symbolIndex, typeId in index.routineReturnTypeIds:
    if not typeId.valid:
      continue
    if symbolIndex >= symbols.len:
      return false
    let descriptor = routineReturnSpan(tokens, symbols[symbolIndex]).descriptor
    if index.descriptorTypeId(descriptor) != typeId:
      return false
  var previousTypeId = InvalidTypeId
  var previousSymbol = 0'u32
  var previousParameter = 0'u32
  for candidateIndex, candidate in index.ufcsProcedures:
    if not candidate.typeId.valid or index.typeKind(candidate.typeId) == typeUnknown or
        candidate.symbolOrdinal >= uint32(symbols.len) or
        candidate.parameterOrdinal >= uint32(scopes.declarations.len):
      return false
    let symbol = symbols[int(candidate.symbolOrdinal)]
    if symbol.kind notin {symbolProc, symbolFunc, symbolMethod}:
      return false
    let parameter = scopes.declarations[int(candidate.parameterOrdinal)]
    if parameter.kind != declarationParameter or
        index.localTypeIds[int(candidate.parameterOrdinal)] != candidate.typeId:
      return false
    let scopeOrdinal = int(uint32(parameter.scope)) - 1
    if scopeOrdinal <= 0 or scopeOrdinal >= scopes.scopes.len or
        scopes.scopes[scopeOrdinal].kind != scopeRoutine or
        scopes.scopes[scopeOrdinal].ownerSymbol != candidate.symbolOrdinal:
      return false
    var firstParameter = -1
    for declarationIndex, declaration in scopes.declarations:
      if declaration.scope == parameter.scope and
          declaration.kind == declarationParameter:
        if firstParameter < 0 or
            declaration.nameToken < scopes.declarations[firstParameter].nameToken:
          firstParameter = declarationIndex
    if firstParameter != int(candidate.parameterOrdinal):
      return false
    if candidateIndex > 0:
      if uint32(candidate.typeId) < uint32(previousTypeId) or
          candidate.typeId == previousTypeId and candidate.symbolOrdinal < previousSymbol or
          candidate.typeId == previousTypeId and
          candidate.symbolOrdinal == previousSymbol and
          candidate.parameterOrdinal <= previousParameter:
        return false
    previousTypeId = candidate.typeId
    previousSymbol = candidate.symbolOrdinal
    previousParameter = candidate.parameterOrdinal
  true
