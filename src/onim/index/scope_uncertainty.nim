import ../syntax/tokens
import ./scope_lexing

type ScopeUncertainty* = enum
  scopeUnsupportedHeader
  scopeUnsupportedDeclaration
  scopeNestedBlock
  scopeConditional
  scopeGenerated
  scopeInclude
  scopeMalformed

proc markMalformed*(
    tokens: TokenStore, uncertainty: var set[ScopeUncertainty]
) {.gcsafe.} =
  var delimiters: seq[char] = @[]
  for token in tokens:
    if malformedToken(token):
      uncertainty.incl scopeMalformed
    if token.kind != tkPunctuation:
      continue
    if pushDelimiter(delimiters, tokens, token):
      continue
    if tokens.tokenTextLen(token) == 1 and
        isClosingDelimiter(tokens.tokenTextChar(token, 0)) and
        not popDelimiter(delimiters, tokens, token):
      uncertainty.incl scopeMalformed
  if delimiters.len > 0:
    uncertainty.incl scopeMalformed

proc markGlobalUncertainty*(
    tokens: TokenStore, uncertainty: var set[ScopeUncertainty]
) {.gcsafe.} =
  for token in tokens:
    if token.kind != tkIdentifier or not validIdentifier(token) or isStropped(token):
      continue
    if token.hasKeywordRole(roleConditional):
      uncertainty.incl scopeConditional
    elif token.hasKeywordRole(roleInclude):
      uncertainty.incl scopeInclude
    elif token.hasKeywordRole(roleGenerated):
      uncertainty.incl scopeGenerated
