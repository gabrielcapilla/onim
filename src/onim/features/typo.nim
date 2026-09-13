import std/sets

import ./completion
import ./completion_context
import ./completion_models
import ./definition
import ./definition_models
import ../index/bindings
import ../index/occurrences
import ../session/workspace
import ../session/workspace_models
import ../stdlib/map
import ../syntax/tokens

type TypoMatch* = object
  startOffset*: int
  endOffset*: int
  name*: string
  suggestion*: string

proc typoAt*(
    workspace: Workspace, source: WorkspaceSnapshot, byteOffset: int, stdlib: StdlibMap
): TypoMatch =
  if workspace == nil or not source.valid or source.index == nil or byteOffset <= 0:
    return
  let tokenIndex = source.index.prefixToken(byteOffset)
  if tokenIndex < 0 or tokenIndex >= source.index.parsed.tokens.len:
    return
  let token = source.index.parsed.tokens[tokenIndex]
  if token.endOffset != byteOffset or not token.validIdentifier or token.isNimKeyword:
    return
  let resolution = resolveDefinitionAtToken(workspace, source, tokenIndex)
  if resolution.kind != definitionUnknown:
    return
  let completion = completeAt(workspace, source, byteOffset, stdlib, false)
  if completion.items.len != 1 or not completion.items[0].recovered:
    return
  result.startOffset = token.startOffset
  result.endOffset = token.endOffset
  result.name = source.index.parsed.tokens.tokenText(token)
  result.suggestion = completion.items[0].label

proc addTypo(result: var seq[TypoMatch], seen: var HashSet[int], match: TypoMatch) =
  if match.suggestion.len == 0 or match.startOffset in seen:
    return
  seen.incl match.startOffset
  result.add match

proc typoMatches*(
    workspace: Workspace, source: WorkspaceSnapshot, stdlib: StdlibMap
): seq[TypoMatch] =
  if workspace == nil or not source.valid or source.index == nil:
    return
  var seen = initHashSet[int]()
  for occurrence in source.index.occurrences.identifiers:
    if occurrence.roles.contains(occurrenceMember) or
        occurrence.roles.contains(occurrenceQualifier):
      continue
    let tokenIndex = int(occurrence.token)
    if tokenIndex < 0 or tokenIndex >= source.index.parsed.tokens.len:
      continue
    let token = source.index.parsed.tokens[tokenIndex]
    if not token.validIdentifier or token.isNimKeyword or
        source.index.resolveBinding(occurrence.token).state != bindingUnknown:
      continue
    result.addTypo(seen, typoAt(workspace, source, token.endOffset, stdlib))
  for occurrence in source.index.occurrences.qualified:
    let tokenIndex = int(occurrence.memberToken)
    if tokenIndex < 0 or tokenIndex >= source.index.parsed.tokens.len:
      continue
    let token = source.index.parsed.tokens[tokenIndex]
    if not token.validIdentifier or token.isNimKeyword:
      continue
    result.addTypo(seen, typoAt(workspace, source, token.endOffset, stdlib))
