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

type IntegerLiteralSign = enum
  integerLiteralInvalid
  integerLiteralNonNegative
  integerLiteralNegative

proc integerDigit(character: char): int8 {.inline.} =
  if character in {'0' .. '9'}:
    return int8(ord(character) - ord('0'))
  if character in {'a' .. 'f'}:
    return int8(ord(character) - ord('a') + 10)
  if character in {'A' .. 'F'}:
    return int8(ord(character) - ord('A') + 10)
  -1

proc parseIntegerToken(
    tokens: TokenStore, token: Token
): tuple[sign: IntegerLiteralSign, magnitude: uint64] =
  let length = tokens.tokenTextLen(token)
  if length == 0:
    return
  for index in 0 ..< length:
    if tokens.tokenTextChar(token, index) == '\'':
      return
  var base = 10'u8
  var first = 0
  if length >= 2 and tokens.tokenTextChar(token, 0) == '0':
    case tokens.tokenTextChar(token, 1)
    of 'b', 'B':
      base = 2'u8
      first = 2
    of 'o', 'O':
      base = 8'u8
      first = 2
    of 'x', 'X':
      base = 16'u8
      first = 2
    else:
      discard
  if first >= length:
    return
  var magnitude = 0'u64
  var digits = 0
  for index in first ..< length:
    let character = tokens.tokenTextChar(token, index)
    if character == '_':
      continue
    let digit = integerDigit(character)
    if digit < 0:
      return
    if uint8(digit) >= base:
      return
    if magnitude > (high(uint64) - uint64(digit)) div uint64(base):
      return
    magnitude = magnitude * uint64(base) + uint64(digit)
    inc digits
  if digits == 0:
    return
  (integerLiteralNonNegative, magnitude)

proc parseIntegerLiteral(
    tokens: TokenStore, first, past: int
): tuple[sign: IntegerLiteralSign, magnitude: uint64] =
  if first < 0 or first >= past or past > tokens.len:
    return
  if past == first + 1 and tokens[first].kind == tkNumber:
    return parseIntegerToken(tokens, tokens[first])
  if past != first + 2 or tokens[first + 1].kind != tkNumber:
    return
  let sign =
    tokens.tokenTextEquals(tokens[first], "-") or
    tokens.tokenTextEquals(tokens[first], "+")
  if not sign:
    return
  result = parseIntegerToken(tokens, tokens[first + 1])
  if result.sign != integerLiteralInvalid and tokens.tokenTextEquals(tokens[first], "-"):
    result.sign = integerLiteralNegative

proc preferredIntegerLiteralKind*(tokens: TokenStore, first, past: int): TypeKind =
  let literal = parseIntegerLiteral(tokens, first, past)
  case literal.sign
  of integerLiteralNonNegative:
    if literal.magnitude <= 255'u64:
      return typeUInt8
    if literal.magnitude <= 65535'u64:
      return typeUInt16
    if literal.magnitude <= 4294967295'u64:
      return typeUInt32
    return typeUInt64
  of integerLiteralNegative:
    if literal.magnitude <= 128'u64:
      return typeInt8
    if literal.magnitude <= 32768'u64:
      return typeInt16
    if literal.magnitude <= 2147483648'u64:
      return typeInt32
    if literal.magnitude <= 9223372036854775808'u64:
      return typeInt64
  of integerLiteralInvalid:
    discard
  typeUnknown

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
      let explicit = numericLiteralKind(tokens, token)
      if explicit != typeInt:
        return explicit
      let preferred = preferredIntegerLiteralKind(tokens, first, past)
      if preferred != typeUnknown:
        return preferred
      return explicit
    return typeUnknown
  if past == first + 2 and tokens[first + 1].kind == tkNumber and (
    tokens.tokenTextEquals(tokens[first], "-") or
    tokens.tokenTextEquals(tokens[first], "+")
  ):
    let explicit = numericLiteralKind(tokens, tokens[first + 1])
    if explicit != typeInt:
      return explicit
    let preferred = preferredIntegerLiteralKind(tokens, first, past)
    if preferred != typeUnknown:
      return preferred
    return explicit
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
