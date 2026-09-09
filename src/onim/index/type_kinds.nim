import ../syntax/tokens
import ./type_declaration_syntax
import ./type_literal_tokens

type TypeKind* = enum
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

const primitiveTypeKinds = [
  typeBool, typeChar, typeString, typeInt, typeFloat, typeInt8, typeInt16, typeInt32,
  typeInt64, typeUInt, typeUInt8, typeUInt16, typeUInt32, typeUInt64, typeFloat32,
  typeFloat64, typeFloat128,
]

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

proc numericLiteralKind*(tokens: TokenStore, token: Token): TypeKind =
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

proc directLiteralKind*(tokens: TokenStore, first, past: int): TypeKind =
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

proc primitiveTypeKind*(tokens: TokenStore, index: int): TypeKind =
  if not validNameToken(tokens, index):
    return typeUnknown
  for kind in TypeKind:
    if not kind.isPrimitiveType:
      continue
    if tokens.tokenTextEquals(tokens[index], kind.primitiveTypeName):
      return kind
  typeUnknown

proc sequenceLiteralElementKind*(tokens: TokenStore, first, past: int): TypeKind =
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
