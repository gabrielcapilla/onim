import std/algorithm

import ./definition
import ../index/bindings
import ../index/occurrences
import ../index/source_index
import ../index/symbols
import ../session/ids
import ../session/workspace
import ../syntax/lexer

type
  SameFileReferences* = object
    supported*: bool
    tokens*: seq[uint32]

  ReferenceMatch* = object
    fileId*: FileId
    contentGeneration*: ContentGeneration
    tokenIndex*: uint32

  ReferencesResult* = object
    supported*: bool
    target*: DefinitionTarget
    matches*: seq[ReferenceMatch]

proc compareReferenceMatches*(left, right: ReferenceMatch): int =
  result = cmp(left.fileId.value, right.fileId.value)
  if result == 0:
    result = cmp(left.tokenIndex, right.tokenIndex)

proc referenceCandidate(occurrence: IdentifierOccurrence): bool {.inline.} =
  occurrenceReference in occurrence.roles and occurrenceQualifier notin occurrence.roles

proc resetResult(result: var ReferencesResult) {.inline.} =
  result = ReferencesResult()

proc resolveSameFileReferences*(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    byteOffset: int,
    includeDeclaration: bool,
): SameFileReferences =
  if workspace == nil or not source.valid or source.index == nil:
    return
  let tokenIndex = tokenAtOffset(source.index.parsed.tokens, byteOffset)
  if tokenIndex < 0:
    return
  let selected = resolveLocalDefinitionAtToken(source, tokenIndex)
  if selected.kind != definitionResolved or selected.target.kind != targetDeclaration or
      selected.target.fileId.value != source.fileId.value:
    return

  if tokenIndex != int(selected.target.nameToken):
    let roles = source.index.occurrences.rolesForToken(uint32(tokenIndex))
    if occurrenceReference notin roles or occurrenceMember in roles:
      return

  result.supported = true
  if includeDeclaration:
    result.tokens.add selected.target.nameToken

  let wanted = identifierKey(
    source.index.parsed.tokens,
    source.index.parsed.tokens[int(selected.target.nameToken)],
  )
  for occurrence in source.index.occurrences.identifiers:
    let occurrenceIndex = int(occurrence.token)
    if occurrenceIndex == int(selected.target.nameToken) or
        identifierKey(
          source.index.parsed.tokens, source.index.parsed.tokens[occurrenceIndex]
        ) != wanted or occurrenceMember in occurrence.roles:
      continue
    let binding = source.index.resolveBinding(occurrence.token)
    if binding.state == bindingResolved and
        binding.declarationToken == selected.target.nameToken:
      result.tokens.add occurrence.token
    elif binding.state != bindingResolved and
        source.index.bindingRegionContains(selected.target.nameToken, occurrence.token):
      result = SameFileReferences()
      return

proc resolveReferences*(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    byteOffset: int,
    includeDeclaration: bool,
): ReferencesResult =
  if workspace == nil or not source.valid or source.index == nil:
    return

  let local =
    resolveSameFileReferences(workspace, source, byteOffset, includeDeclaration)
  if local.supported:
    let tokenIndex = tokenAtOffset(source.index.parsed.tokens, byteOffset)
    let selected = resolveLocalDefinitionAtToken(source, tokenIndex)
    if selected.kind != definitionResolved or selected.target.kind != targetDeclaration:
      return
    result.supported = true
    result.target = selected.target
    for token in local.tokens:
      result.matches.add ReferenceMatch(
        fileId: source.fileId,
        contentGeneration: source.contentGeneration,
        tokenIndex: token,
      )
    return

  if not workspace.graphComplete or not source.index.nativeIndexSafe():
    return

  let tokenIndex = tokenAtOffset(source.index.parsed.tokens, byteOffset)
  if tokenIndex < 0:
    return
  let selected = resolveDefinitionAtToken(workspace, source, tokenIndex)
  if selected.kind != definitionResolved or selected.target.kind != targetDeclaration:
    return
  result.target = selected.target

  let targetView = workspace.indexViewForFile(result.target.fileId)
  if not targetView.valid or targetView.index == nil or
      targetView.id.value != source.id.value or
      targetView.contentGeneration.value != result.target.contentGeneration.value or
      result.target.nameToken >= uint32(targetView.index.parsed.tokens.len) or
      not targetView.index.nativeIndexSafe():
    return
  let targetSymbolIndex = targetView.index.symbols.symbolToken(result.target.nameToken)
  if targetSymbolIndex < 0 or not targetView.index.symbols[targetSymbolIndex].exported:
    return
  let targetName = targetView.index.parsed.tokens.tokenText(
    targetView.index.parsed.tokens[int(result.target.nameToken)]
  )

  var candidateFiles: seq[FileId] = @[result.target.fileId]
  for dependent in workspace.dependents(result.target.fileId):
    var known = false
    for existing in candidateFiles:
      if existing.value == dependent.value:
        known = true
        break
    if not known:
      candidateFiles.add dependent
  candidateFiles.sort(
    proc(left, right: FileId): int =
      cmp(left.value, right.value)
  )
  if includeDeclaration:
    result.matches.add ReferenceMatch(
      fileId: result.target.fileId,
      contentGeneration: result.target.contentGeneration,
      tokenIndex: result.target.nameToken,
    )

  for fileId in candidateFiles:
    let view = workspace.indexViewForFile(fileId)
    if not view.valid or view.index == nil or view.id.value != source.id.value or
        not view.index.nativeIndexSafe():
      result.resetResult()
      return
    if not view.index.occurrences.hasUsage(view.index.parsed.tokens, targetName):
      continue

    let candidate = workspace.snapshotForFile(fileId)
    if not candidate.valid or candidate.id.value != source.id.value or
        candidate.contentGeneration.value != view.contentGeneration.value or
        candidate.index == nil or not candidate.index.nativeIndexSafe():
      result.resetResult()
      return
    let targetKey = identifierKey(targetName)
    for occurrence in candidate.index.occurrences.identifiers:
      if not occurrence.referenceCandidate:
        continue
      let occurrenceIndex = int(occurrence.token)
      if occurrenceIndex < 0 or occurrenceIndex >= candidate.index.parsed.tokens.len or
          identifierKey(
            candidate.index.parsed.tokens,
            candidate.index.parsed.tokens[occurrenceIndex],
          ) != targetKey:
        continue
      let resolution = resolveDefinitionAtToken(workspace, candidate, occurrenceIndex)
      if resolution.kind != definitionResolved:
        result.resetResult()
        return
      if resolution.target.sameDefinitionTarget(result.target):
        result.matches.add ReferenceMatch(
          fileId: candidate.fileId,
          contentGeneration: candidate.contentGeneration,
          tokenIndex: occurrence.token,
        )

  result.matches.sort(compareReferenceMatches)
  result.supported = true
