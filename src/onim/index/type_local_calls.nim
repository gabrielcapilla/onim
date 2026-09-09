import ../syntax/tokens
import ./scopes
import ./type_declaration_syntax
import ./type_expression_syntax
import ./type_kinds
import ./type_local_models
import ./type_queries
import ./type_states

proc directCallInfo*(tokens: TokenStore, first, past: int): LocalTypeInfo =
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

proc typeUseFor*(tokens: TokenStore, declaration: LexicalDeclaration): uint32 =
  let split = splitDeclaration(tokens, declaration)
  if split.equals >= 0:
    let call = directCallInfo(tokens, split.equals + 1, int(declaration.pastToken))
    if call.form == localTypeFormCall:
      return call.typeToken
  InvalidTypeToken
