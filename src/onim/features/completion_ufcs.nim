import std/[strutils, tables]

import ./completion_candidates
import ./completion_models
import ./definition
import ./definition_models
import ../index/source_index
import ../index/symbols
import ../index/types
import ../index/type_states
import ../session/ids
import ../session/workspace
import ../session/workspace_models
import ../syntax/tokens

proc appendUfcsCandidate(
    name, prefixKey: string,
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
): bool =
  let key = identifierKey(name)
  if key.len == 0 or (prefixKey.len > 0 and not key.startsWith(prefixKey)):
    return true
  if candidateByName.hasKey(key) and
      candidates[candidateByName[key]].item.kind == completionField:
    return true
  appendCompletionCandidate(
    name, completionMethod, prefixKey, candidates, candidateByName
  )

proc appendUfcsMembers*(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    receiver: LocalTypeResolution,
    prefixKey: string,
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
): bool =
  let matches = collectUfcsTargets(workspace, source, receiver, prefixKey = prefixKey)
  if matches.state != typeStateResolved:
    return false
  for target in matches.targets:
    var view = workspace.indexViewForFile(target.fileId)
    if target.fileId.value == source.fileId.value and not view.valid:
      view = WorkspaceIndexView(
        valid: source.valid,
        id: source.id,
        fileId: source.fileId,
        contentGeneration: source.contentGeneration,
        index: source.index,
      )
    if not view.valid or view.index == nil or
        target.nameToken >= uint32(view.index.parsed.tokens.len):
      return false
    let symbolIndex = view.index.symbols.symbolToken(target.nameToken)
    if symbolIndex < 0 or symbolIndex >= view.index.symbols.len:
      return false
    let name = view.index.parsed.tokens.tokenText(
      view.index.parsed.tokens[int(target.nameToken)]
    )
    if not appendUfcsCandidate(name, prefixKey, candidates, candidateByName):
      return false
  true
