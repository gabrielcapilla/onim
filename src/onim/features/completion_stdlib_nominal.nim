import std/tables

import ./completion_candidates
import ./completion_models
import ./signature
import ./definition
import ./definition_models
import ./definition_stdlib_type
import ../index/type_kinds
import ../index/type_local_models
import ../session/workspace
import ../session/workspace_models
import ../stdlib/map
import ../stdlib/map_receivers
import ../syntax/tokens

proc appendImplicitFileMembers*(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    stdlib: StdlibMap,
    typeInfo: LocalTypeInfo,
    prefix: string,
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
): bool =
  if typeInfo.kind != typeNamed or
      typeInfo.typeToken >= uint32(source.index.parsed.tokens.len):
    return false
  let typeToken = source.index.parsed.tokens[int(typeInfo.typeToken)]
  if not source.index.parsed.tokens.tokenTextEquals(typeToken, "File"):
    return false
  if resolveDefinitionAtToken(workspace, source, int(typeInfo.typeToken)).kind !=
      definitionUnknown:
    return false
  for candidate in stdlib.implicitFileMembers(prefix):
    result = true
    discard appendStdlibCandidate(
      candidate,
      completionMethod,
      identifierKey(prefix),
      candidates,
      candidateByName,
      signatureMemberCall,
    )

proc appendStdlibNominalMembers*(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    stdlib: StdlibMap,
    localType: LocalTypeResolution,
    prefix: string,
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
): bool =
  let module = stdlibNominalTypeModule(workspace, source, stdlib, localType)
  if module.len == 0:
    return
  let typeName = source.index.parsed.tokens.tokenText(
    source.index.parsed.tokens[int(localType.info.typeToken)]
  )
  let before = candidates.len
  for candidate in stdlib.directNominalMembers(module, typeName, prefix):
    discard appendStdlibCandidate(
      candidate,
      completionMethod,
      identifierKey(prefix),
      candidates,
      candidateByName,
      signatureMemberCall,
    )
  candidates.len > before
