import std/sets

import ./ids
import ./workspace_file_ids
import ./workspace_graph
import ./workspace_models

type InvalidationKind* = enum
  invalidationContent
  invalidationTopology

proc bumpSnapshot*(snapshotId: var SnapshotId) =
  snapshotId = SnapshotId(uint64(snapshotId) + 1'u64)

proc invalidateProjectSurface*(surfaceGeneration: var SurfaceGeneration) =
  surfaceGeneration = SurfaceGeneration(uint64(surfaceGeneration) + 1'u64)

proc bumpWorkspaceGeneration*(generation: var uint64) =
  inc generation

proc invalidateDependents*(
    files: var seq[FileRecord],
    unresolved: HashSet[uint32],
    invalidated: var seq[FileId],
    snapshotId: var SnapshotId,
    root: FileId,
    kind = invalidationContent,
): seq[FileId] =
  result = reverseClosure(files, root)
  case kind
  of invalidationContent:
    discard
  of invalidationTopology:
    for unresolvedId in unresolved:
      for dependent in reverseClosure(files, FileId(unresolvedId)):
        addUniqueId(result, dependent)
  if result.len == 0:
    return
  snapshotId = SnapshotId(uint64(snapshotId) + 1'u64)
  for id in result:
    let index = id.recordIndex
    files[index].dependencyGeneration = DependencyGeneration(uint64(snapshotId))
    addUniqueId(invalidated, id)
  sortIds(invalidated)

proc invalidateAll*(
    files: var seq[FileRecord], invalidated: var seq[FileId], snapshotId: var SnapshotId
) =
  snapshotId = SnapshotId(uint64(snapshotId) + 1'u64)
  for file in files.mitems:
    file.dependencyGeneration = DependencyGeneration(uint64(snapshotId))
    addUniqueId(invalidated, file.id)
  sortIds(invalidated)

proc invalidateBootstrapChanges*(
    previousFiles: openArray[FileRecord],
    files: var seq[FileRecord],
    changedRoots: openArray[FileId],
    invalidated: var seq[FileId],
    snapshotId: var SnapshotId,
) =
  if changedRoots.len == 0:
    return
  var affected: seq[FileId] = @[]
  for root in changedRoots:
    for id in reverseClosure(previousFiles, root):
      addUniqueId(affected, id)
    for id in reverseClosure(files, root):
      addUniqueId(affected, id)
  bumpSnapshot(snapshotId)
  for id in affected:
    let index = id.recordIndex
    if index >= 0 and index < files.len:
      files[index].dependencyGeneration = DependencyGeneration(uint64(snapshotId))
      addUniqueId(invalidated, id)
  sortIds(invalidated)
