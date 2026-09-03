import std/[algorithm, strutils, tables]

import ../syntax/imports
import ../syntax/lexer
import ./symbols

type
  OccurrenceRole* = enum
    occurrenceReference
    occurrenceQualifier
    occurrenceMember
    occurrenceExport

  OccurrenceUncertainty* = enum
    uncertaintyNestedScope
    uncertaintyDeclarationOrder
    uncertaintyConditional
    uncertaintyInclude
    uncertaintyGenerated
    uncertaintyUnsupportedSyntax
    uncertaintyMalformed

  IdentifierOccurrence* = object
    token*: uint32
    roles*: set[OccurrenceRole]

  QualifiedOccurrence* = object
    qualifierToken*: uint32
    memberToken*: uint32

  UsageSummary* = object
    representativeToken*: uint32
    referenceCount*: uint32
    qualifierCount*: uint32
    memberCount*: uint32
    exportCount*: uint32

  OccurrenceIndex* = object
    ## Numeric source-order postings derived from the validated token stream.
    identifiers*: seq[IdentifierOccurrence]
    qualified*: seq[QualifiedOccurrence]
    usage*: seq[UsageSummary]
    uncertainty*: set[OccurrenceUncertainty]

proc malformedIdentifierToken(token: Token): bool {.inline.} =
  token.kind == tkIdentifier and token.text.len == 0 or
    (token.kind == tkIdentifier and not validIdentifier(token))

proc closedStringToken(token: Token): bool =
  if token.kind != tkString or token.text.len < 2:
    return false
  if token.text.startsWith("\"\"\""):
    return token.text.len >= 6 and token.text.endsWith("\"\"\"")
  token.text[0] in {'\"', '\''} and token.text[^1] == token.text[0]

proc declarationKeyword(token: Token): bool {.inline.} =
  if token.kind != tkIdentifier or isStropped(token):
    return false
  token.text == "proc" or token.text == "func" or token.text == "iterator" or
    token.text == "method" or token.text == "macro" or token.text == "template" or
    token.text == "converter" or token.text == "type" or token.text == "var" or
    token.text == "let" or token.text == "const" or token.text == "for" or
    token.text == "bind"

proc markImportSpans(parsed: SourceImports, excluded: var seq[bool]) =
  for item in parsed.imports:
    if item.synthetic or item.endOffset <= item.startOffset:
      continue
    for index, token in parsed.tokens:
      if token.startOffset >= item.startOffset and token.endOffset <= item.endOffset:
        excluded[index] = true

proc markDeclarationNames(tokens: openArray[Token], excluded: var seq[bool]) =
  ## Exclude the small set of declaration heads understood by the existing
  ## source index. Unsupported nested declarations still force fallback.
  var index = 0
  while index < tokens.len:
    let token = tokens[index]
    if not declarationKeyword(token) or excluded[index]:
      inc index
      continue

    var cursor = index + 1
    if token.text in
        ["proc", "func", "iterator", "method", "macro", "template", "converter"]:
      if cursor < tokens.len and tokens[cursor].text == "*":
        inc cursor
      if cursor < tokens.len and tokens[cursor].kind == tkIdentifier:
        excluded[cursor] = true
    elif token.text == "type" or token.text == "var" or token.text == "let" or
        token.text == "const":
      let declarationLine = token.line
      while cursor < tokens.len and tokens[cursor].line == declarationLine:
        if tokens[cursor].text == ":" or tokens[cursor].text == "=":
          break
        if tokens[cursor].kind == tkIdentifier and not isNimKeyword(tokens[cursor]):
          excluded[cursor] = true
        inc cursor
    elif token.text == "for":
      while cursor < tokens.len and tokens[cursor].text != "in" and
          tokens[cursor].text != "=" and tokens[cursor].text != ":":
        if tokens[cursor].kind == tkIdentifier and not isNimKeyword(tokens[cursor]):
          excluded[cursor] = true
        inc cursor
    elif token.text == "bind":
      if cursor < tokens.len and tokens[cursor].kind == tkIdentifier:
        excluded[cursor] = true
    inc index

proc operatorPunctuation(text: string): bool {.inline.} =
  text.len == 1 and
    text[0] in {
      '+', '-', '*', '/', '\\', '<', '>', '=', '@', '$', '~', '&', '%', '!', '?', '^',
      '|',
    }

proc markUncertainty(
    parsed: SourceImports, excluded: seq[bool], result: var OccurrenceIndex
) =
  for item in parsed.imports:
    if item.conditional:
      result.uncertainty.incl uncertaintyConditional

  for index, token in parsed.tokens:
    if token.kind == tkString:
      if not closedStringToken(token):
        result.uncertainty.incl uncertaintyMalformed
      continue

    if token.kind == tkIdentifier:
      if malformedIdentifierToken(token):
        result.uncertainty.incl uncertaintyMalformed
      if excluded[index]:
        continue
      if token.column > 0:
        result.uncertainty.incl uncertaintyNestedScope
      if isStropped(token):
        continue
      if token.text == "when" or token.text == "elif" or token.text == "else" or
          token.text == "static":
        result.uncertainty.incl uncertaintyConditional
      if token.text == "include":
        result.uncertainty.incl uncertaintyInclude
      if token.text == "macro" or token.text == "template" or token.text == "mixin":
        result.uncertainty.incl uncertaintyGenerated
      if declarationKeyword(token):
        result.uncertainty.incl uncertaintyDeclarationOrder
    elif not excluded[index] and operatorPunctuation(token.text):
      result.uncertainty.incl uncertaintyUnsupportedSyntax
    elif not excluded[index] and token.text == "{" and index + 1 < parsed.tokens.len and
        parsed.tokens[index + 1].text == ".":
      result.uncertainty.incl uncertaintyUnsupportedSyntax

  for token in parsed.tokens:
    if token.text == "include":
      result.uncertainty.incl uncertaintyInclude
      break

proc exportUse(tokens: openArray[Token], index: int): bool =
  var cursor = index - 1
  while cursor >= 0 and tokens[cursor].line == tokens[index].line and
      tokens[cursor].text != ";":
    if tokens[cursor].text == "export":
      return true
    dec cursor

proc addUsage(
    index: var OccurrenceIndex,
    lookup: var Table[string, int],
    tokens: openArray[Token],
    occurrence: IdentifierOccurrence,
) =
  let tokenIndex = int(occurrence.token)
  let key = identifierKey(tokens[tokenIndex].text)
  var summaryIndex: int
  if lookup.hasKey(key):
    summaryIndex = lookup[key]
  else:
    summaryIndex = index.usage.len
    lookup[key] = summaryIndex
    index.usage.add UsageSummary(representativeToken: occurrence.token)
  var summary = index.usage[summaryIndex]
  inc summary.referenceCount
  if occurrenceQualifier in occurrence.roles:
    inc summary.qualifierCount
  if occurrenceMember in occurrence.roles:
    inc summary.memberCount
  if occurrenceExport in occurrence.roles:
    inc summary.exportCount
  index.usage[summaryIndex] = summary

proc indexOccurrences*(
    parsed: SourceImports, symbols: openArray[SourceSymbol]
): OccurrenceIndex =
  let tokenCount = parsed.tokens.len
  if tokenCount == 0:
    return

  var excluded = newSeq[bool](tokenCount)
  markImportSpans(parsed, excluded)
  for symbol in symbols:
    if symbol.nameToken < uint32(tokenCount):
      excluded[int(symbol.nameToken)] = true
  markDeclarationNames(parsed.tokens, excluded)
  markUncertainty(parsed, excluded, result)

  var included = newSeq[bool](tokenCount)
  var roles = newSeq[set[OccurrenceRole]](tokenCount)
  var lookup = initTable[string, int]()
  for tokenIndex, token in parsed.tokens:
    if excluded[tokenIndex] or not validIdentifier(token) or isNimKeyword(token):
      continue
    included[tokenIndex] = true
    roles[tokenIndex] = {occurrenceReference}
    if tokenIndex > 1 and parsed.tokens[tokenIndex - 1].text == "." and
        included[tokenIndex - 2]:
      roles[tokenIndex].incl occurrenceMember
    if tokenIndex + 2 < tokenCount and parsed.tokens[tokenIndex + 1].text == "." and
        validIdentifier(parsed.tokens[tokenIndex + 2]) and not excluded[tokenIndex + 2] and
        not isNimKeyword(parsed.tokens[tokenIndex + 2]):
      roles[tokenIndex].incl occurrenceQualifier
    if exportUse(parsed.tokens, tokenIndex):
      roles[tokenIndex].incl occurrenceExport
    let occurrence =
      IdentifierOccurrence(token: uint32(tokenIndex), roles: roles[tokenIndex])
    result.identifiers.add occurrence
    addUsage(result, lookup, parsed.tokens, occurrence)

  for tokenIndex in 0 ..< tokenCount:
    if not included[tokenIndex] or tokenIndex + 2 >= tokenCount or
        parsed.tokens[tokenIndex + 1].text != "." or not included[tokenIndex + 2]:
      continue
    result.qualified.add QualifiedOccurrence(
      qualifierToken: uint32(tokenIndex), memberToken: uint32(tokenIndex + 2)
    )

  result.usage.sort(
    proc(left, right: UsageSummary): int =
      cmp(
        identifierKey(parsed.tokens[int(left.representativeToken)].text),
        identifierKey(parsed.tokens[int(right.representativeToken)].text),
      )
  )

proc isComplete*(index: OccurrenceIndex): bool =
  index.uncertainty == {}

proc usageFor*(
    index: OccurrenceIndex, tokens: openArray[Token], name: string
): UsageSummary =
  let wanted = identifierKey(name)
  if wanted.len == 0:
    return
  for summary in index.usage:
    if summary.representativeToken < uint32(tokens.len) and
        identifierKey(tokens[int(summary.representativeToken)].text) == wanted:
      return summary

proc hasUsage*(index: OccurrenceIndex, tokens: openArray[Token], name: string): bool =
  index.usageFor(tokens, name).referenceCount > 0

proc validateOccurrences*(index: OccurrenceIndex, tokens: openArray[Token]): bool =
  var occurrenceByToken = newSeq[bool](tokens.len)
  var previousToken = high(uint32)
  for occurrence in index.identifiers:
    if occurrence.token >= uint32(tokens.len) or
        (previousToken != high(uint32) and occurrence.token <= previousToken) or
        not occurrence.roles.contains(occurrenceReference) or
        not validIdentifier(tokens[int(occurrence.token)]):
      return false
    occurrenceByToken[int(occurrence.token)] = true
    previousToken = occurrence.token

  var previousQualifier = high(uint32)
  for pair in index.qualified:
    if pair.qualifierToken >= uint32(tokens.len) or
        pair.memberToken >= uint32(tokens.len) or pair.qualifierToken >= pair.memberToken or
        pair.memberToken != pair.qualifierToken + 2'u32 or
        tokens[int(pair.qualifierToken) + 1].text != "." or
        not occurrenceByToken[int(pair.qualifierToken)] or
        not occurrenceByToken[int(pair.memberToken)] or
        (previousQualifier != high(uint32) and pair.qualifierToken <= previousQualifier):
      return false
    previousQualifier = pair.qualifierToken

  var previousKey = ""
  var expected = initTable[string, UsageSummary]()
  for occurrence in index.identifiers:
    let key = identifierKey(tokens[int(occurrence.token)].text)
    if not expected.hasKey(key):
      expected[key] = UsageSummary(representativeToken: occurrence.token)
    var summary = expected[key]
    inc summary.referenceCount
    if occurrenceQualifier in occurrence.roles:
      inc summary.qualifierCount
    if occurrenceMember in occurrence.roles:
      inc summary.memberCount
    if occurrenceExport in occurrence.roles:
      inc summary.exportCount
    expected[key] = summary

  if expected.len != index.usage.len:
    return false
  for summary in index.usage:
    if summary.representativeToken >= uint32(tokens.len):
      return false
    let key = identifierKey(tokens[int(summary.representativeToken)].text)
    if previousKey.len > 0 and key <= previousKey:
      return false
    previousKey = key
    if not expected.hasKey(key) or expected[key] != summary:
      return false
  true
