import ./symbols
import ../syntax/tokens
import ./type_annotation_syntax
import ./type_ids
import ./type_index_models
import ./type_interning
import ./type_kinds
import ./type_local_models
import ./type_queries
import ./type_states

proc routineReturnSpan*(
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
