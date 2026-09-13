import std/strutils

import onim/features/completion
import onim/features/completion_models
import onim/index/source_index
import onim/session/ids as onimIds
import onim/session/workspace
import onim/session/workspace_models
import onim/stdlib/map

proc localSnapshot*(source: string, path = "main.nim"): WorkspaceSnapshot =
  WorkspaceSnapshot(
    valid: true,
    id: onimIds.SnapshotId(1),
    fileId: onimIds.FileId(1),
    path: path,
    text: source,
    contentGeneration: onimIds.ContentGeneration(1),
    index: indexSource(source),
  )

proc completionAt*(source, prefix: string): CompletionResult =
  let snapshot = localSnapshot(source)
  let offset = source.rfind(prefix) + prefix.len
  snapshot.completeLocals(offset)

proc memberCompletionAt*(source, prefix: string): CompletionResult =
  let snapshot = localSnapshot(source)
  let workspace = initWorkspace()
  completeAt(workspace, snapshot, source.rfind(prefix) + prefix.len, emptyStdlibMap())
