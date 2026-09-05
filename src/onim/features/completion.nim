import std/[algorithm, os, sets, strutils, tables]

import ../index/bindings
import ../index/occurrences
import ../index/scopes
import ../index/source_index
import ../index/symbols
import ../session/workspace
import ../syntax/imports
import ../syntax/lexer

type
  CompletionState* = enum
    completionUnsupported
    completionAvailable

  CompletionKind* = enum
    completionVariable
    completionConstant

  CompletionItem* = object
    label*: string
    kind*: CompletionKind

  CompletionResult* = object
    state*: CompletionState
    replaceStart*: int
    replaceEnd*: int
    items*: seq[CompletionItem]

  VisibleCompletion = object
    item: CompletionItem
    key: string
    distance: uint32
    declarationToken: uint32

proc scopeOrdinal(scope: ScopeId): int {.inline.} =
  int(uint32(scope)) - 1

proc prefixToken(index: SourceIndex, byteOffset: int): int =
  if index == nil or byteOffset <= 0 or byteOffset > index.byteLength:
    return -1
  let candidate = index.parsed.tokens.tokenAtOffset(byteOffset - 1)
  if candidate < 0 or candidate >= index.parsed.tokens.len:
    return -1
  if index.parsed.tokens[candidate].endOffset != byteOffset:
    return -1
  candidate

proc declarationToken(index: SourceIndex, tokenIndex: uint32): bool {.inline.} =
  for symbol in index.symbols:
    if symbol.nameToken == tokenIndex:
      return true
  for declaration in index.scopes.declarations:
    if declaration.nameToken == tokenIndex:
      return true
  false

proc completionContext(index: SourceIndex, tokenIndex: int): bool =
  if tokenIndex < 0 or tokenIndex >= index.parsed.tokens.len:
    return false
  let token = index.parsed.tokens[tokenIndex]
  if token.kind != tkIdentifier or not token.validIdentifier or token.isStropped or
      isNimKeyword(token.text) or token.text.len == 0 or
      index.parsed.tokenInsideImport(token) or index.declarationToken(
    uint32(tokenIndex)
  ):
    return false
  if (tokenIndex > 0 and index.parsed.tokens[tokenIndex - 1].text == ".") or (
    tokenIndex + 1 < index.parsed.tokens.len and
    index.parsed.tokens[tokenIndex + 1].text == "."
  ):
    return false
  index.occurrences.rolesForToken(uint32(tokenIndex)) == {occurrenceReference}

proc unsupportedStructure(index: SourceIndex): bool =
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

proc addScopeDistances(
    index: ScopeIndex, active: ScopeId, distances: var Table[uint32, uint32]
): bool =
  var current = active
  while current != InvalidScopeId:
    let ordinal = current.scopeOrdinal
    if ordinal < 0 or ordinal >= index.scopes.len:
      return false
    let scope = index.scopes[ordinal]
    if scope.kind == scopeModule:
      return distances.len > 0
    if scope.kind notin {scopeRoutine, scopeBlock}:
      return false
    distances[uint32(current)] = uint32(distances.len)
    current = index.parentScope(current)
  false

proc compareCompletion(left, right: VisibleCompletion): int =
  result = cmp(left.key, right.key)
  if result != 0:
    return
  result = cmp(left.item.label, right.item.label)
  if result != 0:
    return
  result = cmp(left.declarationToken, right.declarationToken)

proc appendVisible(
    index: SourceIndex,
    active: ScopeId,
    cursorToken: uint32,
    prefix: string,
    distances: Table[uint32, uint32],
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
    scopeNames: var seq[HashSet[string]],
): bool =
  for declaration in index.scopes.declarations:
    let nameIndex = int(declaration.nameToken)
    if nameIndex < 0 or nameIndex >= index.parsed.tokens.len:
      return false
    let token = index.parsed.tokens[nameIndex]
    if token.kind != tkIdentifier or not token.validIdentifier or token.isStropped or
        isNimKeyword(token.text):
      return false
    let distance = distances.getOrDefault(uint32(declaration.scope), high(uint32))
    if distance == high(uint32) or
        not index.scopes.isScopeAncestor(declaration.scope, active):
      continue
    let key = identifierKey(token.text)
    if key.len == 0:
      return false
    let scopeOrdinal = declaration.scope.scopeOrdinal
    if scopeOrdinal <= 0 or scopeOrdinal >= scopeNames.len:
      return false
    if key in scopeNames[scopeOrdinal]:
      return false
    scopeNames[scopeOrdinal].incl key
    if declaration.nameToken >= cursorToken:
      continue
    if not key.startsWith(identifierKey(prefix)):
      continue

    let item = CompletionItem(
      label: token.text,
      kind:
        if declaration.kind == declarationConst:
          completionConstant
        else:
          completionVariable,
    )
    let visible = VisibleCompletion(
      item: item, key: key, distance: distance, declarationToken: declaration.nameToken
    )
    if not candidateByName.hasKey(key):
      candidateByName[key] = candidates.len
      candidates.add visible
    elif distance < candidates[candidateByName[key]].distance:
      candidates[candidateByName[key]] = visible
  true

proc completeLocals*(source: WorkspaceSnapshot, byteOffset: int): CompletionResult =
  if not source.valid or source.index == nil or
      source.path.toLowerAscii.endsWith(".nimble") or
      source.path.toLowerAscii.endsWith(".cfg") or byteOffset < 0 or
      byteOffset > source.text.len or not source.index.bindingsReady or
      source.index.unsupportedStructure:
    return
  let tokenIndex = source.index.prefixToken(byteOffset)
  if tokenIndex < 0 or not source.index.completionContext(tokenIndex):
    return
  if source.index.implicitNameKind(uint32(tokenIndex)) != implicitNone:
    return
  let active = source.index.scopes.innermostScopeAt(uint32(tokenIndex))
  if not source.index.scopes.isLocalScope(active):
    return

  var distances = initTable[uint32, uint32]()
  if not source.index.scopes.addScopeDistances(active, distances):
    return
  var candidates: seq[VisibleCompletion] = @[]
  var candidateByName = initTable[string, int]()
  var scopeNames = newSeq[HashSet[string]](source.index.scopes.scopes.len)
  for scopeIndex in 1 ..< scopeNames.len:
    scopeNames[scopeIndex] = initHashSet[string]()
  if not source.index.appendVisible(
    active,
    uint32(tokenIndex),
    source.index.parsed.tokens[tokenIndex].text,
    distances,
    candidates,
    candidateByName,
    scopeNames,
  ):
    return
  candidates.sort(compareCompletion)
  result.state = completionAvailable
  result.replaceStart = source.index.parsed.tokens[tokenIndex].startOffset
  result.replaceEnd = byteOffset
  result.items = newSeqOfCap[CompletionItem](candidates.len)
  for candidate in candidates:
    result.items.add candidate.item
