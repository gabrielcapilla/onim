import std/[algorithm, sets, strutils]

import ../syntax/imports
import ../syntax/lexer
import ./occurrences
import ./scopes
import ./symbols

export lexer

type
  SourceIndex* = ref object
    contentHash*: uint64
    byteLength*: int
    tokenCount*: int
    parsed*: SourceImports
    symbols*: seq[SourceSymbol]
    scopes*: ScopeIndex
    occurrences*: OccurrenceIndex
    imports*: seq[string]
    exports*: seq[string]
    includes*: seq[string]

  IncrementalEditKind = enum
    incrementalUnsupported
    incrementalIdentifier

  IncrementalEdit = object
    kind: IncrementalEditKind
    tokenIndex: int
    startOffset: int
    oldEndOffset: int

proc contentFingerprint*(source: string): uint64 =
  var fingerprint = 14695981039346656037'u64
  for character in source:
    fingerprint = (fingerprint xor uint64(ord(character))) * 1099511628211'u64
  fingerprint

proc canonicalReference(module: string): string =
  result = module.strip(chars = {'"', '\'', '`'})
  result = result.replace('\\', '/')
  var prefix = ""
  if result.len > 3 and result.startsWith("../"):
    prefix = "../"
    result = result[3 .. ^1]
  elif result.len > 2 and result.startsWith("./"):
    prefix = "./"
    result = result[2 .. ^1]
  result = result.replace('.', '/')
  while result.contains("//"):
    result = result.replace("//", "/")
  result = prefix & result

proc addUnique(values: var seq[string], value: string) =
  if value.len == 0:
    return
  for existing in values:
    if existing == value:
      return
  values.add value

proc locateIncrementalEdit(oldSource, newSource: string): IncrementalEdit =
  let commonLength = min(oldSource.len, newSource.len)
  var start = 0
  while start < commonLength and oldSource[start] == newSource[start]:
    inc start
  var oldEnd = oldSource.len
  var newEnd = newSource.len
  while oldEnd > start and newEnd > start and
      oldSource[oldEnd - 1] == newSource[newEnd - 1]:
    dec oldEnd
    dec newEnd
  if start == oldEnd and start == newEnd or oldEnd - start != newEnd - start:
    return
  for position in start ..< oldEnd:
    if oldSource[position] in {'\n', '\r'} or newSource[position] in {'\n', '\r'}:
      return
  result.startOffset = start
  result.oldEndOffset = oldEnd

proc ordinaryReference(index: SourceIndex, tokenIndex: int): bool =
  index != nil and
    index.occurrences.rolesForToken(uint32(tokenIndex)) == {occurrenceReference}

proc includeReference(index: SourceIndex, tokenIndex: int): bool =
  tokenIndex > 0 and index.parsed.tokens[tokenIndex - 1].isKeyword(kwInclude)

proc nativeIndexSafe*(info: SourceImports, index: SourceIndex): bool =
  if index == nil or index.includes.len > 0 or index.exports.len > 0:
    return false
  for reason in index.scopes.uncertainty:
    case reason
    of scopeNestedBlock:
      discard
    else:
      return false
  for reason in index.occurrences.uncertainty:
    case reason
    of uncertaintyNestedScope, uncertaintyDeclarationOrder:
      discard
    of uncertaintyUnsupportedSyntax:
      for tokenIndex, token in index.parsed.tokens:
        if info.tokenInsideImport(token):
          continue
        if token.kind == tkPunctuation and operatorPunctuation(token.text) and
            token.text != "=":
          return false
        if token.text == "{" and tokenIndex + 1 < index.parsed.tokens.len and
            index.parsed.tokens[tokenIndex + 1].text == ".":
          return false
    else:
      return false
  for item in info.imports:
    if item.synthetic or item.conditional or item.alias.len > 0 or item.excluded.len > 0:
      return false
  true

proc classifyIncrementalEdit(
    oldIndex: SourceIndex, oldSource, newSource: string
): IncrementalEdit =
  if oldIndex == nil or oldIndex.contentHash != contentFingerprint(oldSource) or
      oldIndex.byteLength != oldSource.len or
      oldIndex.tokenCount != oldIndex.parsed.tokens.len:
    return
  result = locateIncrementalEdit(oldSource, newSource)
  if result.oldEndOffset <= result.startOffset:
    result.kind = incrementalUnsupported
    return
  let tokenIndex =
    tokenContaining(oldIndex.parsed.tokens, result.startOffset, result.oldEndOffset)
  if tokenIndex < 0:
    result.kind = incrementalUnsupported
    return
  let token = oldIndex.parsed.tokens[tokenIndex]
  if token.kind != tkIdentifier or not validIdentifier(token) or isNimKeyword(token) or
      isStropped(token) or not oldIndex.ordinaryReference(tokenIndex) or
      oldIndex.includeReference(tokenIndex):
    result.kind = incrementalUnsupported
    return
  let newText = newSource[token.startOffset ..< token.endOffset]
  let replacement = Token(
    kind: tkIdentifier,
    text: newText,
    startOffset: token.startOffset,
    endOffset: token.endOffset,
    line: token.line,
    column: token.column,
  )
  if not validIdentifier(replacement) or isNimKeyword(replacement) or
      isStropped(replacement):
    result.kind = incrementalUnsupported
    return
  result.kind = incrementalIdentifier
  result.tokenIndex = tokenIndex

proc addUsageRoles(summary: var UsageSummary, roles: set[OccurrenceRole]) =
  inc summary.referenceCount
  if occurrenceQualifier in roles:
    inc summary.qualifierCount
  if occurrenceMember in roles:
    inc summary.memberCount
  if occurrenceExport in roles:
    inc summary.exportCount

proc removeUsageRoles(summary: var UsageSummary, roles: set[OccurrenceRole]) =
  if summary.referenceCount > 0:
    dec summary.referenceCount
  if occurrenceQualifier in roles and summary.qualifierCount > 0:
    dec summary.qualifierCount
  if occurrenceMember in roles and summary.memberCount > 0:
    dec summary.memberCount
  if occurrenceExport in roles and summary.exportCount > 0:
    dec summary.exportCount

proc replacementRepresentative[T](
    index: SourceIndex, tokens: T, tokenIndex: int, wanted: string
): uint32 =
  for occurrence in index.occurrences.identifiers:
    let candidate = int(occurrence.token)
    if candidate != tokenIndex and candidate < tokens.len and
        identifierKey(tokens[candidate].text) == wanted:
      return occurrence.token
  high(uint32)

proc patchUsage(
    updated: var SourceIndex,
    oldIndex: SourceIndex,
    tokenIndex: int,
    oldKey, newKey: string,
): bool =
  if oldKey == newKey:
    return true
  let roles = oldIndex.occurrences.rolesForToken(uint32(tokenIndex))
  if roles == {}:
    return false

  updated.occurrences.usage = newSeqOfCap[UsageSummary](oldIndex.occurrences.usage.len)
  for summary in oldIndex.occurrences.usage:
    updated.occurrences.usage.add summary

  var oldUsage = -1
  var newUsage = -1
  for index, summary in updated.occurrences.usage:
    if summary.representativeToken >= uint32(oldIndex.parsed.tokens.len):
      return false
    let key =
      identifierKey(oldIndex.parsed.tokens[int(summary.representativeToken)].text)
    if key == oldKey:
      oldUsage = index
    elif key == newKey:
      newUsage = index
  if oldUsage < 0:
    return false

  var oldSummary = updated.occurrences.usage[oldUsage]
  oldSummary.removeUsageRoles(roles)
  if oldSummary.referenceCount == 0:
    updated.occurrences.usage.delete(oldUsage)
    if newUsage > oldUsage:
      dec newUsage
  else:
    let representative =
      replacementRepresentative(oldIndex, oldIndex.parsed.tokens, tokenIndex, oldKey)
    if representative == high(uint32):
      return false
    oldSummary.representativeToken = representative
    updated.occurrences.usage[oldUsage] = oldSummary

  if newUsage < 0:
    updated.occurrences.usage.add UsageSummary(representativeToken: uint32(tokenIndex))
    newUsage = updated.occurrences.usage.high
  var newSummary = updated.occurrences.usage[newUsage]
  newSummary.addUsageRoles(roles)
  updated.occurrences.usage[newUsage] = newSummary
  updated.occurrences.sortUsage(updated.parsed.tokens)
  true

proc cloneIncrementalIndex(oldIndex: SourceIndex, source: string): SourceIndex =
  new(result)
  result.contentHash = contentFingerprint(source)
  result.byteLength = source.len
  result.tokenCount = oldIndex.tokenCount
  # The parsed sets, import records, and token store are immutable for this
  # fast path. The changed token receives a copy-on-write block below.
  result.parsed = oldIndex.parsed
  result.symbols = oldIndex.symbols
  result.scopes = oldIndex.scopes
  result.occurrences = oldIndex.occurrences
  result.imports = oldIndex.imports
  result.exports = oldIndex.exports
  result.includes = oldIndex.includes

proc tryIndexSourceIncremental*(
    oldSource: string, oldIndex: SourceIndex, source: string
): SourceIndex =
  let edit = classifyIncrementalEdit(oldIndex, oldSource, source)
  if edit.kind != incrementalIdentifier:
    return
  result = cloneIncrementalIndex(oldIndex, source)
  let oldToken = oldIndex.parsed.tokens[edit.tokenIndex]
  let newText = source[oldToken.startOffset ..< oldToken.endOffset]
  var updatedToken = oldToken
  updatedToken.text = newText
  updatedToken.keyword = keywordId(newText)
  result.parsed.tokens = result.parsed.tokens.withToken(edit.tokenIndex, updatedToken)
  let oldKey = identifierKey(oldToken.text)
  let newKey = identifierKey(newText)
  if not result.patchUsage(oldIndex, edit.tokenIndex, oldKey, newKey):
    return nil
  # The edit proof is deliberately narrow: one equal-length, non-keyword
  # identifier reference changed, while every token boundary, neighboring
  # token, declaration, scope, and occurrence role stayed fixed. Revalidating
  # those immutable structures here would turn the fast path back into a full
  # source scan. The complete index path remains the fallback for every edit
  # outside this proof.

proc collectExportReferences[T](tokens: T, start: int): seq[string] =
  var cursor = start + 1
  while cursor < tokens.len:
    if tokens[cursor].isKeyword(kwExcept):
      break
    if tokens[cursor].text == ",":
      inc cursor
      continue
    if tokens[cursor].kind != tkIdentifier:
      break

    var reference = tokens[cursor].text
    inc cursor
    while cursor + 1 < tokens.len and
        (tokens[cursor].text == "/" or tokens[cursor].text == ".") and
        tokens[cursor + 1].kind == tkIdentifier
    :
      reference.add tokens[cursor].text
      reference.add tokens[cursor + 1].text
      inc cursor, 2
    addUnique(result, canonicalReference(reference))
    if cursor >= tokens.len or tokens[cursor].text != ",":
      break

proc indexSource*(source: string): SourceIndex {.gcsafe.} =
  new(result)
  result.contentHash = contentFingerprint(source)
  result.byteLength = source.len
  result.parsed = parseSourceImports(source)
  result.tokenCount = result.parsed.tokens.len
  result.symbols = indexSymbols(source, result.parsed.tokens)
  result.scopes = indexScopes(result.parsed.tokens, result.symbols, result.byteLength)
  result.occurrences = indexOccurrences(result.parsed, result.symbols)

  for item in result.parsed.imports:
    addUnique(result.imports, canonicalReference(item.module))

  for tokenIndex, token in result.parsed.tokens:
    if token.isKeyword(kwExport):
      for reference in collectExportReferences(result.parsed.tokens, tokenIndex):
        addUnique(result.exports, reference)

  for tokenIndex, token in result.parsed.tokens:
    if not token.isKeyword(kwInclude) or tokenIndex + 1 >= result.parsed.tokens.len:
      continue
    var includeName = canonicalReference(result.parsed.tokens[tokenIndex + 1].text)
    if includeName.len == 0:
      continue
    if not includeName.endsWith(".nim"):
      includeName.add ".nim"
    addUnique(result.includes, includeName)

  result.imports.sort
  result.includes.sort
