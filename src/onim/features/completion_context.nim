import ./definition_receiver_tokens
import ../index/occurrences
import ../index/source_index
import ../syntax/imports
import ../syntax/import_queries
import ../syntax/tokens

type
  MemberContextState* = enum
    memberContextAbsent
    memberContextInvalid
    memberContextReady

  MemberQualifierKind* = enum
    qualifierIdentifier
    qualifierIndexedSequence

  MemberContext* = object
    state*: MemberContextState
    qualifierKind*: MemberQualifierKind
    qualifierToken*: int
    indexToken*: int
    prefix*: string
    replaceStart*: int
    replaceEnd*: int

proc prefixToken*(index: SourceIndex, byteOffset: int): int =
  if index == nil or byteOffset <= 0 or byteOffset > index.byteLength:
    return -1
  let candidate = index.parsed.tokens.tokenAtOffset(byteOffset - 1)
  if candidate < 0 or candidate >= index.parsed.tokens.len:
    return -1
  if index.parsed.tokens[candidate].endOffset != byteOffset:
    return -1
  candidate

proc memberContext*(index: SourceIndex, byteOffset: int): MemberContext =
  if index == nil or byteOffset <= 0 or byteOffset > index.byteLength:
    return
  let candidate = index.parsed.tokens.tokenContaining(byteOffset - 1, byteOffset)
  if candidate < 0 or index.parsed.tokens[candidate].endOffset != byteOffset:
    return

  var dotToken = -1
  var memberToken = -1
  let token = index.parsed.tokens[candidate]
  if token.kind == tkIdentifier:
    memberToken = candidate
    dotToken = candidate - 1
    result.replaceStart = token.startOffset
    result.replaceEnd = byteOffset
  elif token.kind == tkPunctuation and index.parsed.tokens.tokenTextEquals(token, "."):
    dotToken = candidate
    result.replaceStart = byteOffset
    result.replaceEnd = byteOffset
  else:
    return

  if dotToken < 0 or dotToken >= index.parsed.tokens.len or
      index.parsed.tokens[dotToken].kind != tkPunctuation or
      not index.parsed.tokens.tokenTextEquals(index.parsed.tokens[dotToken], "."):
    if memberToken >= 0:
      return
    result.state = memberContextInvalid
    return

  let dot = index.parsed.tokens[dotToken]
  let qualifier = qualifierBeforeDot(index.parsed.tokens, dotToken)
  if qualifier.qualifier < 0 or
      index.parsed.tokens[dotToken - 1].endOffset != dot.startOffset:
    result.state = memberContextInvalid
    return
  if memberToken >= 0:
    let member = index.parsed.tokens[memberToken]
    if member.line != dot.line or member.startOffset != dot.endOffset or
        not member.validIdentifier or member.isStropped or member.isNimKeyword:
      result.state = memberContextInvalid
      return

  result.state = memberContextReady
  result.qualifierKind =
    if qualifier.indexToken >= 0: qualifierIndexedSequence else: qualifierIdentifier
  result.qualifierToken = qualifier.qualifier
  result.indexToken = qualifier.indexToken
  result.prefix =
    if memberToken >= 0:
      index.parsed.tokens.tokenText(index.parsed.tokens[memberToken])
    else:
      ""

proc declarationToken(index: SourceIndex, tokenIndex: uint32): bool {.inline.} =
  for symbol in index.symbols:
    if symbol.nameToken == tokenIndex:
      return true
  for declaration in index.scopes.declarations:
    if declaration.nameToken == tokenIndex:
      return true
  false

proc completionContext*(index: SourceIndex, tokenIndex: int): bool =
  if tokenIndex < 0 or tokenIndex >= index.parsed.tokens.len:
    return false
  let token = index.parsed.tokens[tokenIndex]
  if token.kind != tkIdentifier or not token.validIdentifier or token.isStropped or
      token.isNimKeyword or index.parsed.tokens.tokenTextLen(token) == 0 or
      index.parsed.tokenInsideImport(token) or index.declarationToken(
    uint32(tokenIndex)
  ):
    return false
  if (
    tokenIndex > 0 and
    index.parsed.tokens.tokenTextEquals(index.parsed.tokens[tokenIndex - 1], ".")
  ) or (
    tokenIndex + 1 < index.parsed.tokens.len and
    index.parsed.tokens.tokenTextEquals(index.parsed.tokens[tokenIndex + 1], ".")
  ):
    return false
  index.occurrences.rolesForToken(uint32(tokenIndex)) == {occurrenceReference}
