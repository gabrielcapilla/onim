import ../syntax/tokens
import ./scopes
import ./type_declaration_syntax
import ./type_expression_syntax
import ./type_field_syntax
import ./type_kinds
import ./type_index_models
import ./type_queries
import ./type_local_calls
import ./type_tuple_literals

type
  GenericArgumentDescriptor* = object
    kind*: TypeKind
    nameToken*: uint32

  TypeDescriptor* = object
    kind*: TypeKind
    nameToken*: uint32
    baseKind*: TypeKind
    baseNameToken*: uint32
    extent*: uint32
    genericArguments*: seq[GenericArgumentDescriptor]

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

proc annotationDescriptor*(tokens: TokenStore, first, past: int): TypeDescriptor =
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

proc declarationTypeDescriptor*(
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
