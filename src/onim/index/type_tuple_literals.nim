import ../syntax/tokens
import ./type_field_syntax
import ./type_index_models
import ./type_literal_tokens

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

proc sequenceLiteralTupleFields*(
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
