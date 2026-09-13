import std/strutils

import onim/features/definition
import onim/features/definition_models
import onim/index/type_states
import onim/session/ids
import onim/session/workspace
import onim/session/workspace_models
import onim/syntax/tokens

proc resolveLast*(
    workspace: Workspace, fileId: FileId, name: string
): DefinitionResolution =
  let snapshot = workspace.snapshotForFile(fileId)
  resolveDefinition(workspace, snapshot, snapshot.text.rfind(name))

proc providerSource*(): string =
  """proc answer() = discard
export answer
proc privateAnswer() = discard
proc overload*(value: int) = discard
proc overload*(value: string) = discard
proc forward*()
proc forward*() = discard
"""

proc typeStateFor*(
    workspace: Workspace, snapshot: WorkspaceSnapshot, name: string
): TypeState =
  for declaration in snapshot.index.scopes.declarations:
    let token = snapshot.index.parsed.tokens[int(declaration.nameToken)]
    if snapshot.index.parsed.tokens.tokenTextEquals(token, name):
      return workspace.resolveLocalType(snapshot, declaration.nameToken).info.state
  typeStateUnknown
