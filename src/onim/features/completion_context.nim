import std/strutils

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
    insertStart*: int
    insertEnd*: int
    replaceStart*: int
    replaceEnd*: int

  InterpolationContextState* = enum
    interpolationAbsent
    interpolationInvalid
    interpolationReady

  InterpolationContext* = object
    state*: InterpolationContextState
    prefix*: string
    replaceStart*: int
    replaceEnd*: int
    anchorToken*: int
    identifierStart*: int
    identifierPast*: int

proc prefixToken*(index: SourceIndex, byteOffset: int): int =
  if index == nil or byteOffset <= 0 or byteOffset > index.byteLength:
    return -1
  let candidate = index.parsed.tokens.tokenAtOffset(byteOffset - 1)
  if candidate < 0 or candidate >= index.parsed.tokens.len:
    return -1
  if index.parsed.tokens[candidate].endOffset != byteOffset:
    return -1
  candidate

proc previousToken*(index: SourceIndex, byteOffset: int): int =
  if index == nil or byteOffset < 0 or byteOffset > index.byteLength:
    return -1
  let tokens = index.parsed.tokens
  var first = 0
  var past = tokens.len
  while first < past:
    let middle = (first + past) div 2
    if tokens[middle].endOffset <= byteOffset:
      first = middle + 1
    else:
      past = middle
  first - 1

proc identifierAtCursor(index: SourceIndex, byteOffset: int): int {.inline.} =
  if index == nil or byteOffset < 0 or byteOffset > index.byteLength:
    return -1
  let tokens = index.parsed.tokens
  if byteOffset > 0:
    let previous = tokens.tokenContaining(byteOffset - 1, byteOffset)
    if previous >= 0 and tokens[previous].kind == tkIdentifier and
        tokens[previous].endOffset == byteOffset:
      return previous
  if byteOffset < index.byteLength:
    let current = tokens.tokenContaining(byteOffset, byteOffset + 1)
    if current >= 0 and tokens[current].kind == tkIdentifier:
      return current
  -1

proc horizontalGap*(source: string, first, past: int): bool =
  if first < 0 or past < first or past > source.len:
    return false
  for character in source[first ..< past]:
    if character notin {' ', '\t'}:
      return false
  true

proc memberContext*(index: SourceIndex, byteOffset: int): MemberContext =
  if index == nil or byteOffset < 0 or byteOffset > index.byteLength:
    return
  let tokens = index.parsed.tokens
  var dotToken = -1
  let memberToken = identifierAtCursor(index, byteOffset)
  if memberToken >= 0:
    dotToken = memberToken - 1
    result.insertStart = tokens[memberToken].startOffset
    result.insertEnd = byteOffset
    result.replaceStart = tokens[memberToken].startOffset
    result.replaceEnd = tokens[memberToken].endOffset
  elif byteOffset > 0:
    let candidate = tokens.tokenContaining(byteOffset - 1, byteOffset)
    if candidate < 0 or tokens[candidate].endOffset != byteOffset or
        tokens[candidate].kind != tkPunctuation or
        not tokens.tokenTextEquals(tokens[candidate], "."):
      return
    dotToken = candidate
    result.insertStart = byteOffset
    result.insertEnd = byteOffset
    result.replaceStart = byteOffset
    result.replaceEnd = byteOffset

  if dotToken < 0 or dotToken >= tokens.len or tokens[dotToken].kind != tkPunctuation or
      not tokens.tokenTextEquals(tokens[dotToken], "."):
    if memberToken >= 0:
      return
    result.state = memberContextInvalid
    return

  let dot = tokens[dotToken]
  let qualifier = qualifierBeforeDot(tokens, dotToken)
  if qualifier.qualifier < 0 or tokens[dotToken - 1].endOffset != dot.startOffset:
    result.state = memberContextInvalid
    return
  if memberToken >= 0:
    let member = tokens[memberToken]
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
      let first = tokens[memberToken].startOffset
      let past = min(max(byteOffset, first), tokens[memberToken].endOffset)
      if past > first:
        tokens.sourceText[first ..< past]
      else:
        ""
    else:
      ""

proc interpolationIdentifierStart(character: char): bool {.inline.} =
  character == '_' or character.isAlphaAscii or ord(character) >= 128

proc interpolationIdentifierContinue(character: char): bool {.inline.} =
  interpolationIdentifierStart(character) or character.isDigit

proc skipInterpolationComment(source: string, cursor: var int) =
  if cursor + 1 < source.len and source[cursor + 1] == '[':
    cursor += 2
    var depth = 1
    while cursor < source.len and depth > 0:
      if cursor + 1 < source.len and source[cursor] == '#' and source[cursor + 1] == '[':
        cursor += 2
        inc depth
      elif cursor + 1 < source.len and source[cursor] == ']' and
          source[cursor + 1] == '#':
        cursor += 2
        dec depth
      else:
        inc cursor
  else:
    while cursor < source.len and source[cursor] != '\n':
      inc cursor

proc quotedEnd(source: string, quoteStart: int): tuple[past: int, contentStart: int] =
  let triple =
    quoteStart + 2 < source.len and source[quoteStart ..< quoteStart + 3] == "\"\"\""
  var cursor = quoteStart + (if triple: 3 else: 1)
  result.contentStart = cursor
  while cursor < source.len:
    if not triple and source[cursor] == '\\':
      cursor += min(2, source.len - cursor)
    elif triple and cursor + 2 < source.len and source[cursor ..< cursor + 3] == "\"\"\"":
      return (cursor + 3, result.contentStart)
    elif not triple and source[cursor] == '"':
      return (cursor + 1, result.contentStart)
    else:
      inc cursor
  (source.len, result.contentStart)

proc prefixedQuote(source: string, cursor: int): int {.inline.} =
  if cursor + 3 < source.len and source[cursor ..< cursor + 4] == "fmt\"" and
      (cursor == 0 or not interpolationIdentifierContinue(source[cursor - 1])):
    return cursor + 3
  if cursor + 1 < source.len and source[cursor] == '&' and source[cursor + 1] == '"':
    return cursor + 1
  -1

proc interpolationAt(
    source: string, quoteStart, byteOffset, stringPast: int
): InterpolationContext =
  let quoted = quotedEnd(source, quoteStart)
  let contentStart = quoted.contentStart
  let contentPast = min(quoted.past, stringPast)
  if byteOffset < contentStart or byteOffset > contentPast:
    return
  var opening = -1
  var cursor = contentStart
  let limit = min(byteOffset, contentPast)
  while cursor < limit:
    if source[cursor] == '\\':
      cursor += min(2, limit - cursor)
    elif source[cursor] == '{':
      if cursor + 1 < limit and source[cursor + 1] == '{':
        cursor += 2
      elif opening < 0:
        opening = cursor
        inc cursor
      else:
        result.state = interpolationInvalid
        return
    elif source[cursor] == '}':
      if cursor + 1 < limit and source[cursor + 1] == '}':
        cursor += 2
      elif opening >= 0:
        opening = -1
        inc cursor
      else:
        result.state = interpolationInvalid
        return
    else:
      inc cursor
  if opening < 0:
    return
  let prefixStart = opening + 1
  for position in prefixStart ..< limit:
    if not interpolationIdentifierContinue(source[position]):
      result.state = interpolationInvalid
      return
  result.state = interpolationReady
  result.replaceStart = prefixStart
  result.replaceEnd = limit
  if limit > prefixStart:
    result.prefix = source[prefixStart ..< limit]
  result.identifierStart = prefixStart
  result.identifierPast = prefixStart
  while result.identifierPast < contentPast and
      interpolationIdentifierContinue(source[result.identifierPast]):
    inc result.identifierPast

proc previousTokenAt(index: SourceIndex, byteOffset: int): int {.inline.} =
  if index == nil:
    return -1
  for tokenIndex, token in index.parsed.tokens:
    if token.endOffset <= byteOffset:
      result = tokenIndex
    elif token.startOffset > byteOffset:
      break

proc interpolationContext*(index: SourceIndex, byteOffset: int): InterpolationContext =
  if index == nil or byteOffset < 0 or byteOffset > index.byteLength:
    return
  let source = index.parsed.tokens.sourceText
  var cursor = 0
  while cursor < source.len:
    if source[cursor] == '#':
      skipInterpolationComment(source, cursor)
      continue
    let quoteStart = prefixedQuote(source, cursor)
    if quoteStart >= 0:
      let quoted = quotedEnd(source, quoteStart)
      if byteOffset >= quoteStart and byteOffset <= quoted.past:
        result = interpolationAt(source, quoteStart, byteOffset, quoted.past)
        if result.state == interpolationReady:
          let previous = previousTokenAt(index, quoteStart)
          result.anchorToken = previous
        return
      cursor = quoted.past
      continue
    if source[cursor] in {'"', '\''}:
      cursor = quotedEnd(source, cursor).past
    else:
      inc cursor

proc declarationToken*(index: SourceIndex, tokenIndex: uint32): bool {.inline.} =
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
