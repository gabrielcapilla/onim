import ./definition
import ./definition_models
import ./definition_routine_filter
import ./definition_symbol_target
import ./references
import ../index/occurrences
import ../index/scopes
import ../index/scope_queries
import ../index/source_index
import ../index/symbols
import ../session/ids
import ../session/workspace
import ../session/workspace_models
import ../syntax/tokens

type
  CallHierarchyRelation* = object
    caller*: DefinitionTarget
    callee*: DefinitionTarget
    callToken*: uint32

  CallHierarchyResult* = object
    supported*: bool
    needsBootstrap*: bool
    target*: DefinitionTarget
    calls*: seq[CallHierarchyRelation]

proc routineSymbolIndex*(
    view: WorkspaceIndexView, target: DefinitionTarget
): int {.inline.} =
  if not view.valid or view.index == nil or target.kind != targetDeclaration:
    return -1
  result = view.index.symbols.symbolToken(target.nameToken)
  if result < 0 or not routineKind(view.index.symbols[result].kind):
    return -1

proc routineScopeAt(source: WorkspaceSnapshot, tokenIndex: uint32): int =
  if not source.valid or source.index == nil:
    return -1
  var scope = source.index.scopes.innermostScopeAt(tokenIndex)
  while scope != InvalidScopeId:
    let ordinal = int(uint32(scope)) - 1
    if ordinal < 0 or ordinal >= source.index.scopes.scopes.len:
      return -1
    let interval = source.index.scopes.scopes[ordinal]
    if interval.kind == scopeRoutine:
      if interval.ownerSymbol < uint32(source.index.symbols.len):
        return int(interval.ownerSymbol)
      return -1
    scope = source.index.scopes.parentScope(scope)
  -1

proc routineTargetAt(
    workspace: Workspace, source: WorkspaceSnapshot, tokenIndex: uint32
): DefinitionResolution =
  let symbolIndex = routineScopeAt(source, tokenIndex)
  if symbolIndex < 0:
    return
  resolveSymbolTarget(source, workspace.indexViewForFile(source.fileId), symbolIndex)

proc callToken(tokens: TokenStore, tokenIndex: uint32): bool {.inline.} =
  let index = int(tokenIndex)
  index >= 0 and index + 1 < tokens.len and
    tokens.tokenTextEquals(tokens[index + 1], "(")

proc resolvedCallTarget(
    workspace: Workspace, source: WorkspaceSnapshot, tokenIndex: uint32
): DefinitionResolution =
  let index = int(tokenIndex)
  if not callToken(source.index.parsed.tokens, tokenIndex):
    return
  let resolution = resolveDefinitionAtToken(workspace, source, index)
  if resolution.kind != definitionResolved:
    return
  let view = workspace.indexViewForFile(resolution.target.fileId)
  if view.routineSymbolIndex(resolution.target) >= 0:
    result = resolution

proc hierarchyTargetAt*(
    workspace: Workspace, source: WorkspaceSnapshot, byteOffset: int
): CallHierarchyResult =
  if workspace == nil or not source.valid or source.index == nil:
    return
  if not source.index.nativeIndexSafe():
    return
  let tokenIndex = tokenAtOffset(source.index.parsed.tokens, byteOffset)
  if tokenIndex < 0:
    return
  let resolution = resolveDefinitionAtToken(workspace, source, tokenIndex)
  if resolution.kind == definitionUnresolved:
    result.needsBootstrap =
      workspace.bootstrapState in
      {workspaceBootstrapPending, workspaceBootstrapIncomplete}
    return
  if resolution.kind != definitionResolved:
    return
  let view = workspace.indexViewForFile(resolution.target.fileId)
  if view.routineSymbolIndex(resolution.target) < 0:
    return
  result.supported = true
  result.target = resolution.target

proc appendIncomingCall(
    output: var CallHierarchyResult,
    workspace: Workspace,
    target: DefinitionTarget,
    candidate: WorkspaceSnapshot,
    tokenIndex: uint32,
): bool =
  if not candidate.valid or candidate.index == nil or
      not candidate.index.parsed.tokens.callToken(tokenIndex):
    return
  let resolution = resolveDefinitionAtToken(workspace, candidate, int(tokenIndex))
  if resolution.kind != definitionResolved or
      not resolution.target.sameDefinitionTarget(target):
    return
  let caller = routineTargetAt(workspace, candidate, tokenIndex)
  if caller.kind != definitionResolved:
    return
  output.calls.add CallHierarchyRelation(
    caller: caller.target, callee: target, callToken: tokenIndex
  )
  true

proc incomingCalls*(
    workspace: Workspace, source: WorkspaceSnapshot, byteOffset: int
): CallHierarchyResult =
  result = workspace.hierarchyTargetAt(source, byteOffset)
  if not result.supported:
    return
  let references = resolveReferences(workspace, source, byteOffset, true)
  if references.supported:
    for match in references.matches:
      if match.fileId.value == result.target.fileId.value and
          match.tokenIndex == result.target.nameToken:
        continue
      let candidate = workspace.snapshotForFile(match.fileId)
      if not candidate.valid or candidate.index == nil or
          candidate.contentGeneration.value != match.contentGeneration.value:
        continue
      discard
        result.appendIncomingCall(workspace, result.target, candidate, match.tokenIndex)
    return
  if result.target.fileId.value != source.fileId.value:
    result.supported = false
    result.needsBootstrap =
      workspace.bootstrapState in
      {workspaceBootstrapPending, workspaceBootstrapIncomplete}
    return
  for occurrence in source.index.occurrences.identifiers:
    if occurrence.token != result.target.nameToken:
      discard
        result.appendIncomingCall(workspace, result.target, source, occurrence.token)

proc outgoingCalls*(
    workspace: Workspace, source: WorkspaceSnapshot, byteOffset: int
): CallHierarchyResult =
  result = workspace.hierarchyTargetAt(source, byteOffset)
  if not result.supported:
    return
  let owner = routineScopeAt(source, result.target.nameToken)
  if owner < 0:
    return
  var interval: ScopeInterval
  var foundInterval = false
  for scope in source.index.scopes.scopes:
    if scope.kind == scopeRoutine and scope.ownerSymbol == uint32(owner):
      interval = scope
      foundInterval = true
      break
  if not foundInterval:
    return
  var index = int(interval.firstToken)
  while index < int(interval.pastToken):
    let token = source.index.parsed.tokens[index]
    if token.kind == tkIdentifier and validIdentifier(token) and
        source.index.occurrences.rolesForToken(uint32(index)) != {}:
      let callee = resolvedCallTarget(workspace, source, uint32(index))
      if callee.kind == definitionResolved:
        result.calls.add CallHierarchyRelation(
          caller: result.target, callee: callee.target, callToken: uint32(index)
        )
    inc index
