import std/[algorithm, tables]

import ../syntax/imports
import ../syntax/tokens
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
  token.kind == tkIdentifier and not validIdentifier(token)

proc declarationKeyword(token: Token): bool {.inline.} =
  token.hasKeywordRole(roleDeclaration)

proc markImportSpans(parsed: SourceImports, excluded: var seq[bool]) =
  for item in parsed.imports:
    if item.synthetic or item.endOffset <= item.startOffset:
      continue
    for index, token in parsed.tokens:
      if token.startOffset >= item.startOffset and token.endOffset <= item.endOffset:
        excluded[index] = true

proc markDeclarationNames(tokens: TokenStore, excluded: var seq[bool]) =
  ## Exclude the small set of declaration heads understood by the existing
  ## source index. Unsupported nested declarations still force fallback.
  var index = 0
  while index < tokens.len:
    let token = tokens[index]
    if not declarationKeyword(token) or excluded[index]:
      inc index
      continue

    var cursor = index + 1
    if token.hasKeywordRole(roleRoutine):
      if cursor < tokens.len and tokens.tokenTextEquals(tokens[cursor], "*"):
        inc cursor
      if cursor < tokens.len and tokens[cursor].kind == tkIdentifier:
        excluded[cursor] = true
    elif token.hasKeywordRole(roleTypeDeclaration) or
        token.hasKeywordRole(roleValueDeclaration):
      let declarationLine = token.line
      while cursor < tokens.len and tokens[cursor].line == declarationLine:
        if tokens.tokenTextEquals(tokens[cursor], ":") or
            tokens.tokenTextEquals(tokens[cursor], "="):
          break
        if tokens[cursor].kind == tkIdentifier and not isNimKeyword(tokens[cursor]):
          excluded[cursor] = true
        inc cursor
    elif token.hasKeywordRole(roleForBinding):
      while cursor < tokens.len and not tokens.tokenTextEquals(tokens[cursor], "in") and
          not tokens.tokenTextEquals(tokens[cursor], "=") and
          not tokens.tokenTextEquals(tokens[cursor], ":")
      :
        if tokens[cursor].kind == tkIdentifier and not isNimKeyword(tokens[cursor]):
          excluded[cursor] = true
        inc cursor
    elif token.hasKeywordRole(roleBindDeclaration):
      if cursor < tokens.len and tokens[cursor].kind == tkIdentifier:
        excluded[cursor] = true
    inc index

proc operatorPunctuation*(tokens: TokenStore, token: Token): bool {.inline.} =
  tokens.tokenTextLen(token) == 1 and
    tokens.tokenTextChar(token, 0) in {
      '+', '-', '*', '/', '\\', '<', '>', '=', '@', '$', '~', '&', '%', '!', '?', '^',
      '|',
    }

proc markUncertainty(
    parsed: SourceImports, excluded: seq[bool], result: var OccurrenceIndex
) =
  for item in parsed.imports:
    if item.conditional and
        parsed.conditionalImportDisposition(item) == importConditionalUnknown:
      result.uncertainty.incl uncertaintyConditional

  for index, token in parsed.tokens:
    if token.kind == tkString:
      if not isClosedString(token):
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
      if token.hasKeywordRole(roleConditional):
        if parsed.conditionalTokenDisposition(token) == importConditionalUnknown:
          result.uncertainty.incl uncertaintyConditional
      if token.hasKeywordRole(roleInclude):
        result.uncertainty.incl uncertaintyInclude
      if token.hasKeywordRole(roleGenerated):
        result.uncertainty.incl uncertaintyGenerated
      if declarationKeyword(token):
        result.uncertainty.incl uncertaintyDeclarationOrder
    elif not excluded[index] and operatorPunctuation(parsed.tokens, token):
      if parsed.tokens.tokenTextEquals(token, "=") and
          parsed.tokens.isRoutineHeaderEquals(index):
        continue
      if parsed.tokens.isExportMarker(index):
        continue
      result.uncertainty.incl uncertaintyUnsupportedSyntax
    elif not excluded[index] and parsed.tokens.tokenTextEquals(token, "{") and
        index + 1 < parsed.tokens.len and
        parsed.tokens.tokenTextEquals(parsed.tokens[index + 1], "."):
      result.uncertainty.incl uncertaintyUnsupportedSyntax

  for token in parsed.tokens:
    if token.isKeyword(kwInclude):
      result.uncertainty.incl uncertaintyInclude
      break

proc exportUse(tokens: TokenStore, index: int): bool =
  var cursor = index - 1
  while cursor >= 0 and tokens[cursor].line == tokens[index].line and
      not tokens.tokenTextEquals(tokens[cursor], ";"):
    if tokens[cursor].isKeyword(kwExport):
      return true
    dec cursor

proc addUsage(
    index: var OccurrenceIndex,
    lookup: var Table[string, int],
    tokens: TokenStore,
    occurrence: IdentifierOccurrence,
) =
  let tokenIndex = int(occurrence.token)
  let key = identifierKey(tokens, tokens[tokenIndex])
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

proc sortUsage*(index: var OccurrenceIndex, tokens: TokenStore) =
  index.usage.sort(
    proc(left, right: UsageSummary): int =
      cmp(
        identifierKey(tokens, tokens[int(left.representativeToken)]),
        identifierKey(tokens, tokens[int(right.representativeToken)]),
      )
  )

proc rolesForToken*(index: OccurrenceIndex, token: uint32): set[OccurrenceRole] =
  var first = 0
  var past = index.identifiers.len
  while first < past:
    let middle = (first + past) div 2
    let candidate = index.identifiers[middle].token
    if candidate < token:
      first = middle + 1
    elif candidate > token:
      past = middle
    else:
      return index.identifiers[middle].roles

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
    if tokenIndex > 1 and
        parsed.tokens.tokenTextEquals(parsed.tokens[tokenIndex - 1], ".") and
        included[tokenIndex - 2]:
      roles[tokenIndex].incl occurrenceMember
    if tokenIndex + 2 < tokenCount and
        parsed.tokens.tokenTextEquals(parsed.tokens[tokenIndex + 1], ".") and
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
        not parsed.tokens.tokenTextEquals(parsed.tokens[tokenIndex + 1], ".") or
        not included[tokenIndex + 2]:
      continue
    result.qualified.add QualifiedOccurrence(
      qualifierToken: uint32(tokenIndex), memberToken: uint32(tokenIndex + 2)
    )
  result.sortUsage(parsed.tokens)

proc isComplete*(index: OccurrenceIndex): bool =
  index.uncertainty == {}

template usagePosition(
    index: OccurrenceIndex, tokens: TokenStore, wanted: string
): int =
  block:
    var usageFirst = 0
    var usagePast = index.usage.len
    while wanted.len > 0 and usageFirst < usagePast:
      let usageMiddle = (usageFirst + usagePast) div 2
      let usageSummary = index.usage[usageMiddle]
      if usageSummary.representativeToken >= uint32(tokens.len):
        usageFirst = index.usage.len
        usagePast = usageFirst
      else:
        let usageKey =
          identifierKey(tokens, tokens[int(usageSummary.representativeToken)])
        if usageKey < wanted:
          usageFirst = usageMiddle + 1
        else:
          usagePast = usageMiddle
    if usageFirst < index.usage.len and
        index.usage[usageFirst].representativeToken < uint32(tokens.len) and
        identifierKey(tokens, tokens[int(index.usage[usageFirst].representativeToken)]) ==
        wanted: usageFirst else: -1

proc usageFor*(index: OccurrenceIndex, tokens: TokenStore, name: string): UsageSummary =
  let position = usagePosition(index, tokens, identifierKey(name))
  if position >= 0:
    return index.usage[position]

proc hasUsage*(index: OccurrenceIndex, tokens: TokenStore, name: string): bool =
  index.usageFor(tokens, name).referenceCount > 0

proc validateOccurrences*(index: OccurrenceIndex, tokens: TokenStore): bool =
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
        not tokens.tokenTextEquals(tokens[int(pair.qualifierToken) + 1], ".") or
        not occurrenceByToken[int(pair.qualifierToken)] or
        not occurrenceByToken[int(pair.memberToken)] or
        (previousQualifier != high(uint32) and pair.qualifierToken <= previousQualifier):
      return false
    previousQualifier = pair.qualifierToken

  var previousKey = ""
  var observed = newSeq[UsageSummary](index.usage.len)
  for usageIndex, summary in index.usage:
    if summary.representativeToken >= uint32(tokens.len):
      return false
    let key = identifierKey(tokens, tokens[int(summary.representativeToken)])
    if previousKey.len > 0 and key <= previousKey:
      return false
    previousKey = key
    observed[usageIndex].representativeToken = summary.representativeToken

  for occurrence in index.identifiers:
    let key = identifierKey(tokens, tokens[int(occurrence.token)])
    let position = usagePosition(index, tokens, key)
    if position < 0:
      return false
    var summary = observed[position]
    inc summary.referenceCount
    if occurrenceQualifier in occurrence.roles:
      inc summary.qualifierCount
    if occurrenceMember in occurrence.roles:
      inc summary.memberCount
    if occurrenceExport in occurrence.roles:
      inc summary.exportCount
    observed[position] = summary

  for usageIndex, summary in index.usage:
    let actual = observed[usageIndex]
    if actual.representativeToken != summary.representativeToken or
        actual.referenceCount != summary.referenceCount or
        actual.qualifierCount != summary.qualifierCount or
        actual.memberCount != summary.memberCount or
        actual.exportCount != summary.exportCount:
      return false
  true
