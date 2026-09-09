import std/[algorithm, sets, strutils]

import ../syntax/imports
import ../syntax/include_parser
import ../syntax/export_parser
import ../syntax/import_queries
import ../syntax/module_names
import ../syntax/tokens
import ./occurrences
import ./scopes
import ./scope_uncertainty
import ./symbols
import ./type_literal_tokens
import ./type_index_models
import ./types
import ./type_field_queries
import ../syntax/parser

type
  NativeIndexSafety = enum
    nativeSafetyUncomputed
    nativeSafetyRejected
    nativeSafetyAccepted

  SourceIndex* = ref object
    contentHash*: uint64
    byteLength*: int
    tokenCount*: int
    parsed*: SourceImports
    syntax*: PartialSyntaxTree
    symbols*: seq[SourceSymbol]
    scopes*: ScopeIndex
    types*: TypeIndex
    occurrences*: OccurrenceIndex
    imports*: seq[string]
    exports*: seq[string]
    hasUnresolvedExports*: bool
    includes*: seq[string]
    nativeSafety: NativeIndexSafety

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

proc moduleAliasesSafe(info: SourceImports): bool =
  var aliases = initHashSet[string]()
  var hasAlias = false
  for item in info.imports:
    let disposition = info.conditionalImportDisposition(item)
    if disposition == importConditionalUnknown:
      return false
    if disposition == importConditionalInactive:
      continue
    if item.alias.len == 0:
      continue
    hasAlias = true
    if item.form != importModule or item.synthetic or item.excluded.len > 0 or
        isNimKeyword(item.alias) or identifierKey(item.alias).len == 0:
      return false
  if not hasAlias:
    return true
  for item in info.imports:
    let disposition = info.conditionalImportDisposition(item)
    if disposition == importConditionalUnknown:
      return false
    if item.synthetic or disposition == importConditionalInactive or
        item.form != importModule:
      continue
    let qualifier =
      if item.alias.len > 0:
        item.alias
      else:
        moduleLeaf(item.module)
    let key = identifierKey(qualifier)
    if key.len == 0 or key in aliases:
      return false
    aliases.incl key
  true

proc deriveNativeIndexSafety(
    info: SourceImports, index: SourceIndex
): NativeIndexSafety =
  if index == nil or index.includes.len > 0 or index.hasUnresolvedExports or
      not info.moduleAliasesSafe:
    return nativeSafetyRejected
  for reason in index.scopes.uncertainty:
    case reason
    of scopeNestedBlock, scopeConditional:
      discard
    else:
      return nativeSafetyRejected
  for reason in index.occurrences.uncertainty:
    case reason
    of uncertaintyNestedScope, uncertaintyDeclarationOrder:
      discard
    of uncertaintyUnsupportedSyntax:
      for tokenIndex, token in index.parsed.tokens:
        if info.tokenInsideImport(token):
          continue
        if sequenceLiteralStart(info.tokens, tokenIndex):
          continue
        if token.kind == tkPunctuation and operatorPunctuation(info.tokens, token) and
            not info.tokens.tokenTextEquals(token, "="):
          if info.tokens.tokenTextEquals(token, "*") and (
            index.types.objectFieldExportMarker(uint32(tokenIndex)) or
            index.parsed.tokens.isExportMarker(tokenIndex)
          ):
            continue
          return nativeSafetyRejected
        if info.tokens.tokenTextEquals(token, "{") and
            tokenIndex + 1 < index.parsed.tokens.len and
            info.tokens.tokenTextEquals(index.parsed.tokens[tokenIndex + 1], "."):
          return nativeSafetyRejected
    else:
      return nativeSafetyRejected
  for item in info.imports:
    if item.synthetic or
        info.conditionalImportDisposition(item) == importConditionalUnknown or
        item.excluded.len > 0:
      return nativeSafetyRejected
  nativeSafetyAccepted

proc initializeNativeIndexSafety*(index: SourceIndex) =
  if index != nil:
    index.nativeSafety = deriveNativeIndexSafety(index.parsed, index)

proc nativeIndexSafe*(index: SourceIndex): bool {.inline.} =
  index != nil and index.nativeSafety == nativeSafetyAccepted

proc unsupportedStructure*(index: SourceIndex): bool =
  for symbol in index.symbols:
    if symbol.kind in {symbolMacro, symbolTemplate}:
      return true
  for token in index.parsed.tokens:
    if token.kind != tkIdentifier or token.isStropped or
        index.parsed.tokenInsideImport(token):
      continue
    if token.hasKeywordRole(roleConditional) or token.hasKeywordRole(roleInclude) or
        token.hasKeywordRole(roleGenerated):
      return true
    if token.hasKeywordRole(roleBlock) and not token.isKeyword(kwBlock):
      return true
  false

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
  var replacement = token
  replacement.keyword = keywordIdAt(newSource, token.startOffset, token.endOffset)
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

proc replacementRepresentative(
    index: SourceIndex, tokens: TokenStore, tokenIndex: int, wanted: string
): uint32 =
  for occurrence in index.occurrences.identifiers:
    let candidate = int(occurrence.token)
    if candidate != tokenIndex and candidate < tokens.len and
        identifierKey(tokens, tokens[candidate]) == wanted:
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
    let key = identifierKey(
      oldIndex.parsed.tokens, oldIndex.parsed.tokens[int(summary.representativeToken)]
    )
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
  # The parsed sets and import records are immutable for this fast path. The
  # successor owns the new source while sharing the token metadata.
  result.parsed = oldIndex.parsed
  result.parsed.tokens = oldIndex.parsed.tokens.rebindSource(source)
  result.syntax = oldIndex.syntax
  result.syntax.tokens = result.parsed.tokens
  result.symbols = oldIndex.symbols
  result.scopes = oldIndex.scopes
  result.types = oldIndex.types
  result.occurrences = oldIndex.occurrences
  result.imports = oldIndex.imports
  result.exports = oldIndex.exports
  result.hasUnresolvedExports = oldIndex.hasUnresolvedExports
  result.includes = oldIndex.includes
  result.nativeSafety = oldIndex.nativeSafety

proc tryIndexSourceIncremental*(
    oldSource: string, oldIndex: SourceIndex, source: string
): SourceIndex =
  let edit = classifyIncrementalEdit(oldIndex, oldSource, source)
  if edit.kind != incrementalIdentifier:
    return
  result = cloneIncrementalIndex(oldIndex, source)
  let oldToken = oldIndex.parsed.tokens[edit.tokenIndex]
  let oldKey = identifierKey(oldIndex.parsed.tokens, oldToken)
  let newKey =
    identifierKey(result.parsed.tokens, result.parsed.tokens[edit.tokenIndex])
  if not result.patchUsage(oldIndex, edit.tokenIndex, oldKey, newKey):
    return nil
  # The edit proof is deliberately narrow: one equal-length, non-keyword
  # identifier reference changed, while every token boundary, neighboring
  # token, declaration, scope, and occurrence role stayed fixed. Revalidating
  # those immutable structures here would turn the fast path back into a full
  # source scan. The complete index path remains the fallback for every edit
  # outside this proof.

proc collectExportReferences(tokens: TokenStore, start, finish: int): seq[string] =
  var cursor = start + 1
  while cursor < finish:
    if tokens[cursor].isKeyword(kwExcept):
      break
    if tokens.tokenTextEquals(tokens[cursor], ","):
      inc cursor
      continue
    if tokens[cursor].kind != tkIdentifier:
      break

    var reference = tokens.tokenText(tokens[cursor])
    inc cursor
    while cursor + 1 < finish and (
      tokens.tokenTextEquals(tokens[cursor], "/") or
      tokens.tokenTextEquals(tokens[cursor], ".")
    ) and tokens[cursor + 1].kind == tkIdentifier
    :
      reference.add tokens.tokenText(tokens[cursor])
      reference.add tokens.tokenText(tokens[cursor + 1])
      inc cursor, 2
    addUnique(result, canonicalReference(reference))
    if cursor >= finish or not tokens.tokenTextEquals(tokens[cursor], ","):
      break

proc importedExportConflict(info: SourceImports, name: string): bool =
  let wanted = identifierKey(name)
  if wanted.len == 0:
    return true
  for item in info.imports:
    if item.form == fromModule:
      for imported in item.imported:
        if identifierKey(imported) == wanted:
          return true
    else:
      let qualifier =
        if item.alias.len > 0:
          item.alias
        else:
          moduleLeaf(item.module)
      if identifierKey(qualifier) == wanted:
        return true
  false

proc moduleLevelSymbol(index: SourceIndex, symbol: SourceSymbol): bool =
  let nameToken = int(symbol.nameToken)
  if nameToken < 0 or nameToken >= index.parsed.tokens.len:
    return false
  for nodeId in index.syntax.declarationNodes:
    let node = index.syntax.nodes[int(uint32(nodeId)) - 1]
    let first = int(node.firstToken)
    if first < 0 or first >= index.parsed.tokens.len or
        index.parsed.tokens[first].column != 0 or
        index.parsed.tokens[nameToken].line != index.parsed.tokens[first].line:
      continue
    if nameToken >= first and nameToken < int(node.pastToken):
      return true
  false

proc resolveLocalExports(index: SourceIndex) =
  for node in index.syntax.nodes:
    if node.kind != syntaxExport:
      continue
    let start = int(node.firstToken)
    if node.uncertainty != {} or start < 0 or start >= index.parsed.tokens.len or
        index.parsed.tokens[start].column != 0:
      index.hasUnresolvedExports = true
      continue
    let parsed = parseExportNames(index.parsed.tokens, start)
    if parsed.uncertainty != {} or parsed.next != int(node.pastToken):
      index.hasUnresolvedExports = true
      continue
    for name in parsed.names:
      if index.parsed.importedExportConflict(name):
        index.hasUnresolvedExports = true
        continue
      var match = -1
      var matches = 0
      let wanted = identifierKey(name)
      for symbolIndex, symbol in index.symbols:
        if not index.moduleLevelSymbol(symbol):
          continue
        let tokenIndex = int(symbol.nameToken)
        if index.parsed.tokens.identifierKey(index.parsed.tokens[tokenIndex]) == wanted:
          inc matches
          match = symbolIndex
      if matches == 1:
        index.symbols[match].exported = true
      else:
        index.hasUnresolvedExports = true

proc indexSource*(source: string): SourceIndex {.gcsafe.} =
  new(result)
  result.contentHash = contentFingerprint(source)
  result.byteLength = source.len
  result.parsed = parseSourceImports(source)
  result.syntax = parsePartialSyntax(result.parsed.tokens, source)
  result.tokenCount = result.parsed.tokens.len
  result.symbols = indexSymbols(source, result.parsed.tokens)
  result.resolveLocalExports()
  result.scopes =
    indexScopes(result.parsed.tokens, result.symbols, result.byteLength, result.syntax)
  result.types = indexTypes(result.parsed.tokens, result.symbols, result.scopes)
  result.occurrences = indexOccurrences(result.parsed, result.symbols)

  for item in result.parsed.imports:
    addUnique(result.imports, canonicalReference(item.module))

  for node in result.syntax.nodes:
    if node.kind == syntaxExport and node.uncertainty == {}:
      for reference in collectExportReferences(
        result.parsed.tokens, int(node.firstToken), int(node.pastToken)
      ):
        addUnique(result.exports, reference)

  for node in result.syntax.nodes:
    if node.kind != syntaxInclude or node.uncertainty != {}:
      continue
    let parsed =
      parseIncludeReferences(result.parsed.tokens, source, int(node.firstToken))
    if parsed.uncertainty != {} or parsed.next != int(node.pastToken):
      continue
    for reference in parsed.references:
      var includeName = reference.module
      if not includeName.endsWith(".nim"):
        includeName.add ".nim"
      addUnique(result.includes, includeName)

  result.imports.sort
  result.includes.sort
  result.initializeNativeIndexSafety()
