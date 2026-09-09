import std/[algorithm, sets, tables]

import ../index/cache
import ./ids
import ./paths
import ./workspace_models

proc adoptManifest*(
    target: var ProjectManifest,
    manifestByPath: var Table[string, ManifestEntry],
    surfaceGeneration: var SurfaceGeneration,
    value: ProjectManifest,
) =
  target = value
  surfaceGeneration = SurfaceGeneration(uint64(surfaceGeneration) + 1'u64)
  manifestByPath.clear()
  for entry in value.entries:
    manifestByPath[entry.path] = entry

proc buildManifestCandidate*(
    root: string,
    previous: ProjectManifest,
    manifestByPath: Table[string, ManifestEntry],
    files: openArray[FileRecord],
    paths: Table[string, FileId],
    unresolved: HashSet[uint32],
): tuple[available: bool, manifest: ProjectManifest] =
  var entries: seq[ManifestEntry] = @[]
  var graphValid = true
  var projectFileCount = 0
  for file in files:
    if not pathWithin(root, file.path):
      graphValid = false
      continue
    inc projectFileCount
    if file.state != workspaceOnDisk:
      graphValid = false
      continue
    let stamp = fileStamp(file.path)
    if stamp.size < 0 or file.stamp.size < 0 or not sameFileStamp(stamp, file.stamp):
      graphValid = false
      continue
    var sourceHash: uint64
    var byteLength: int64
    if file.index != nil:
      sourceHash = file.index.contentHash
      byteLength = int64(file.index.byteLength)
    elif manifestByPath.hasKey(file.path):
      let prior = manifestByPath[file.path]
      if prior.byteLength < 0 or prior.byteLength != stamp.size:
        graphValid = false
        continue
      sourceHash = prior.sourceHash
      byteLength = prior.byteLength
    else:
      graphValid = false
      continue
    entries.add ManifestEntry(
      path: file.path,
      sourceHash: sourceHash,
      byteLength: byteLength,
      stamp: stamp,
      unresolved: uint32(file.id) in unresolved,
    )
  graphValid = graphValid and entries.len == projectFileCount
  if not graphValid and previous.graphValid:
    return
  entries.sort(
    proc(left, right: ManifestEntry): int =
      cmp(left.path, right.path)
  )
  if graphValid:
    var ordinals = initTable[string, uint32]()
    for ordinal, entry in entries:
      ordinals[entry.path] = uint32(ordinal)
    for ordinal, entry in entries:
      let id = paths[entry.path]
      for dependency in files[id.slot].forward:
        let dependencyIndex = dependency.slot
        if dependencyIndex < 0 or dependencyIndex >= files.len or
            files[dependencyIndex].state != workspaceOnDisk or
            not ordinals.hasKey(files[dependencyIndex].path):
          graphValid = false
          break
        entries[ordinal].forwardOrdinals.add(ordinals[files[dependencyIndex].path])
      if not graphValid:
        break
      entries[ordinal].forwardOrdinals.sort
  result.available = true
  result.manifest = ProjectManifest(
    root: root,
    entries: entries,
    graphValid: graphValid,
    directories: previous.directories,
    discoveryValid: previous.discoveryValid,
  )
