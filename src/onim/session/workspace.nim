import std/[algorithm, sets, strutils, tables]
import std/os except FileId

import ../index/cache
import ../index/source_index
import ../index/surfaces
import ./bootstrap_worker
import ./ids
import ./module_catalog
import ./paths
import ./source_discovery

type
  WorkspaceFileState* = enum
    workspaceMissing
    workspaceOnDisk
    workspaceOpen

  WorkspaceBootstrapState* = enum
    workspaceBootstrapPending
    workspaceBootstrapIncomplete
    workspaceBootstrapComplete
    workspaceBootstrapFailed

  DependencyRestoreMode = enum
    restoreIndexed
    restoreLazy

  InvalidationKind = enum
    invalidationContent
    invalidationTopology

  WorkspaceSnapshot* = object
    valid*: bool
    id*: SnapshotId
    fileId*: FileId
    path*: string
    uri*: string
    version*: int64
    text*: string
    state*: WorkspaceFileState
    contentGeneration*: ContentGeneration
    dependencyGeneration*: DependencyGeneration
    configGeneration*: ConfigGeneration
    surfaceGeneration*: SurfaceGeneration
    index*: SourceIndex

  WorkspaceIndexView* = object
    valid*: bool
    id*: SnapshotId
    fileId*: FileId
    path*: string
    uri*: string
    contentGeneration*: ContentGeneration
    index*: SourceIndex

  FileRecord = object
    id: FileId
    path: string
    uri: string
    text: string
    textLoaded: bool
    stamp: FileStamp
    state: WorkspaceFileState
    version: int64
    contentGeneration: ContentGeneration
    dependencyGeneration: DependencyGeneration
    index: SourceIndex
    forward: seq[FileId]
    reverse: seq[FileId]

  Workspace* = ref object
    root*: string
    manifest*: ProjectManifest
    bootstrapState*: WorkspaceBootstrapState
    bootstrapAttempt: ConfigGeneration
    snapshotId: SnapshotId
    configGeneration: ConfigGeneration
    workspaceGeneration: uint64
    nextFileId: uint32
    nextContentGeneration: uint64
    surfaceGeneration: SurfaceGeneration
    files: seq[FileRecord]
    paths: Table[string, FileId]
    manifestByPath: Table[string, ManifestEntry]
    invalidated: seq[FileId]
    unresolved: HashSet[uint32]
    moduleCatalogCache: ModuleCatalog
    projectSurfaceCache: SurfaceIndex
    projectSurfaceBuiltGeneration: SurfaceGeneration
    projectSurfaceInputs: seq[SurfaceInput]
    projectSurfaceInputGenerations: seq[uint64]
    projectSurfaceInputCandidateCounts: seq[uint32]

proc unknownStamp(): FileStamp =
  FileStamp(size: -1, modifiedSeconds: -1, modifiedNanoseconds: -1)

proc invalidateProjectSurface(workspace: Workspace)

proc adoptManifest(workspace: Workspace, manifest: ProjectManifest) =
  workspace.manifest = manifest
  workspace.invalidateProjectSurface()
  workspace.manifestByPath.clear()
  for entry in manifest.entries:
    workspace.manifestByPath[entry.path] = entry

proc initWorkspace*(root = ""): Workspace =
  new(result)
  result.root = canonicalPath(root)
  result.bootstrapState = workspaceBootstrapPending
  result.bootstrapAttempt = InvalidConfigGeneration
  result.snapshotId = SnapshotId(1'u64)
  result.configGeneration = ConfigGeneration(1'u64)
  result.workspaceGeneration = 1
  result.nextFileId = 1
  result.nextContentGeneration = 1
  result.paths = initTable[string, FileId]()
  result.manifestByPath = initTable[string, ManifestEntry]()
  result.unresolved = initHashSet[uint32]()
  result.adoptManifest(loadProjectManifest(result.root))

proc prepareWorkspace*(workspace: Workspace, root: string): bool =
  let canonicalRoot = canonicalPath(root)
  if canonicalRoot.len == 0:
    return false
  if canonicalRoot == workspace.root:
    return true
  if workspace.files.len > 0:
    return false
  workspace.root = canonicalRoot
  workspace.bootstrapState = workspaceBootstrapPending
  workspace.bootstrapAttempt = InvalidConfigGeneration
  inc workspace.workspaceGeneration
  workspace.moduleCatalogCache = nil
  workspace.adoptManifest(loadProjectManifest(workspace.root))
  true

proc markBootstrapIncomplete(workspace: Workspace) =
  if workspace.bootstrapState == workspaceBootstrapPending:
    workspace.bootstrapState = workspaceBootstrapIncomplete

proc bumpSnapshot(workspace: Workspace) =
  workspace.snapshotId = SnapshotId(uint64(workspace.snapshotId) + 1'u64)

proc bumpWorkspaceGeneration(workspace: Workspace) =
  inc workspace.workspaceGeneration

proc nextContent(workspace: Workspace): ContentGeneration =
  result = ContentGeneration(workspace.nextContentGeneration)
  inc workspace.nextContentGeneration

proc indexDiskSource(workspace: Workspace, path, source: string): SourceIndex =
  result = loadCachedSourceIndex(workspace.root, path, source)
  if result == nil:
    result = indexSource(source)
    discard saveCachedSourceIndex(workspace.root, path, source, result)

proc invalidateProjectSurface(workspace: Workspace) =
  workspace.surfaceGeneration =
    SurfaceGeneration(uint64(workspace.surfaceGeneration) + 1'u64)

proc persistManifest(workspace: Workspace) =
  if workspace.bootstrapState != workspaceBootstrapComplete:
    return
  var entries: seq[ManifestEntry] = @[]
  var graphValid = true
  for index in 0 ..< workspace.files.len:
    let file = workspace.files[index]
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
    elif workspace.manifestByPath.hasKey(file.path):
      let previous = workspace.manifestByPath[file.path]
      if previous.byteLength < 0 or previous.byteLength != stamp.size:
        graphValid = false
        continue
      sourceHash = previous.sourceHash
      byteLength = previous.byteLength
    else:
      graphValid = false
      continue
    entries.add ManifestEntry(
      path: file.path,
      sourceHash: sourceHash,
      byteLength: byteLength,
      stamp: stamp,
      unresolved: uint32(file.id) in workspace.unresolved,
    )
  graphValid = graphValid and entries.len == workspace.files.len
  if not graphValid and workspace.manifest.graphValid:
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
      let id = workspace.paths[entry.path]
      for dependency in workspace.files[id.slot].forward:
        let dependencyIndex = dependency.slot
        if dependencyIndex < 0 or dependencyIndex >= workspace.files.len or
            workspace.files[dependencyIndex].state != workspaceOnDisk or
            not ordinals.hasKey(workspace.files[dependencyIndex].path):
          graphValid = false
          break
        entries[ordinal].forwardOrdinals.add(
          ordinals[workspace.files[dependencyIndex].path]
        )
      if not graphValid:
        break
      entries[ordinal].forwardOrdinals.sort
  let directories = workspace.manifest.directories
  let discoveryValid = workspace.manifest.discoveryValid
  workspace.adoptManifest(
    ProjectManifest(
      root: workspace.root,
      entries: entries,
      graphValid: graphValid,
      directories: directories,
      discoveryValid: discoveryValid,
    )
  )
  discard saveProjectManifestWithDiscovery(
    workspace.root, entries, graphValid, directories, discoveryValid
  )

proc ensureRecord(
    workspace: Workspace, path: string
): tuple[id: FileId, created: bool] =
  let key = canonicalPath(path)
  if key.len == 0:
    return (InvalidFileId, false)
  if workspace.paths.hasKey(key):
    return (workspace.paths[key], false)

  let id = FileId(workspace.nextFileId)
  inc workspace.nextFileId
  workspace.markBootstrapIncomplete()
  workspace.moduleCatalogCache = nil
  workspace.paths[key] = id
  workspace.files.add FileRecord(
    id: id,
    path: key,
    state: workspaceMissing,
    version: -1,
    contentGeneration: InvalidContentGeneration,
    dependencyGeneration: InvalidDependencyGeneration,
    textLoaded: false,
    stamp: unknownStamp(),
    forward: @[],
    reverse: @[],
  )
  (id, true)

proc recordIndex(id: FileId): int =
  id.slot

proc addUniqueId(values: var seq[FileId], value: FileId) =
  if not value.valid:
    return
  for existing in values:
    if uint32(existing) == uint32(value):
      return
  values.add value

proc sortIds(values: var seq[FileId]) =
  values.sort(
    proc(left, right: FileId): int =
      cmp(uint32(left), uint32(right))
  )

proc removeId(values: var seq[FileId], value: FileId) =
  var writeIndex = 0
  for current in values:
    if uint32(current) != uint32(value):
      values[writeIndex] = current
      inc writeIndex
  values.setLen(writeIndex)

proc moduleCatalog*(workspace: Workspace): ModuleCatalog =
  if workspace == nil:
    return
  if workspace.moduleCatalogCache != nil:
    return workspace.moduleCatalogCache
  var files = newSeqOfCap[ModuleFile](workspace.files.len)
  for file in workspace.files:
    if file.state != workspaceMissing:
      files.add ModuleFile(id: file.id, path: file.path)
  workspace.moduleCatalogCache = buildModuleCatalog(workspace.root, files)
  workspace.moduleCatalogCache

proc rebuildDependencies(workspace: Workspace)
proc invalidateAll(workspace: Workspace)
proc replaceDependencies(workspace: Workspace, id: FileId)
proc reverseClosure(workspace: Workspace, root: FileId): seq[FileId]
proc stableDiskSource(
  path: string
): tuple[valid: bool, source: string, stamp: FileStamp]

proc cloneFileRecord(file: FileRecord): FileRecord =
  result = file
  result.forward = newSeqOfCap[FileId](file.forward.len)
  for dependency in file.forward:
    result.forward.add dependency
  result.reverse = newSeqOfCap[FileId](file.reverse.len)
  for dependent in file.reverse:
    result.reverse.add dependent

proc cloneWorkspaceState(workspace: Workspace): Workspace =
  new(result)
  result.root = workspace.root
  result.manifest = workspace.manifest
  result.manifest.directories =
    newSeqOfCap[ManifestDirectory](workspace.manifest.directories.len)
  for directory in workspace.manifest.directories:
    result.manifest.directories.add directory
  result.manifest.entries = newSeqOfCap[ManifestEntry](workspace.manifest.entries.len)
  for entry in workspace.manifest.entries:
    var copied = entry
    copied.forwardOrdinals = newSeqOfCap[uint32](entry.forwardOrdinals.len)
    for ordinal in entry.forwardOrdinals:
      copied.forwardOrdinals.add ordinal
    result.manifest.entries.add copied
  result.bootstrapState = workspace.bootstrapState
  result.bootstrapAttempt = workspace.bootstrapAttempt
  result.snapshotId = workspace.snapshotId
  result.configGeneration = workspace.configGeneration
  result.workspaceGeneration = workspace.workspaceGeneration
  result.nextFileId = workspace.nextFileId
  result.nextContentGeneration = workspace.nextContentGeneration
  result.surfaceGeneration = workspace.surfaceGeneration
  result.files = newSeqOfCap[FileRecord](workspace.files.len)
  for file in workspace.files:
    result.files.add cloneFileRecord(file)
  result.paths = initTable[string, FileId]()
  for path, id in workspace.paths:
    result.paths[path] = id
  result.manifestByPath = initTable[string, ManifestEntry]()
  for path, entry in workspace.manifestByPath:
    result.manifestByPath[path] = entry
  result.invalidated = newSeqOfCap[FileId](workspace.invalidated.len)
  for id in workspace.invalidated:
    result.invalidated.add id
  result.unresolved = initHashSet[uint32]()
  for id in workspace.unresolved:
    result.unresolved.incl id

proc replaceManifestEntry(value: var ProjectManifest, entry: ManifestEntry) =
  value.entries.add entry

proc bootstrapManifest(value: BootstrapResult): ProjectManifest =
  result.root = canonicalPath(value.root)
  result.graphValid = true
  result.directories = value.directories
  result.discoveryValid = value.discoveryValid
  var ordinals = initTable[string, uint32]()
  for ordinal, file in value.files:
    ordinals[file.path] = uint32(ordinal)
  for file in value.files:
    var entry = ManifestEntry(
      path: file.path,
      sourceHash: file.sourceHash,
      byteLength: int64(file.byteLength),
      stamp: file.stamp,
      unresolved: file.unresolved,
    )
    for dependency in file.forward:
      if ordinals.hasKey(dependency):
        entry.forwardOrdinals.add ordinals[dependency]
    entry.forwardOrdinals.sort
    result.replaceManifestEntry(entry)

proc validBootstrapPath(root, path: string): bool =
  path != root and pathWithin(root, path)

proc validBootstrapDirectoryPath(root, path: string): bool =
  path == root or validBootstrapPath(root, path)

proc validBootstrapResult(workspace: Workspace, value: BootstrapResult): bool =
  if value.kind != bootstrapComplete or canonicalPath(value.root) != workspace.root or
      value.workspaceGeneration != workspace.workspaceGeneration or
      value.configGeneration != uint64(workspace.configGeneration):
    return false
  if value.discoveryValid:
    if value.directories.len == 0:
      return false
    var directoryPaths = initHashSet[string]()
    var previousDirectory = ""
    var hasRoot = false
    for directory in value.directories:
      let path = canonicalPath(directory.path)
      if path != directory.path or not validBootstrapDirectoryPath(workspace.root, path) or
          path in directoryPaths or
          (previousDirectory.len > 0 and path <= previousDirectory) or
          not usableStamp(directory.stamp):
        return false
      directoryPaths.incl path
      previousDirectory = path
      hasRoot = hasRoot or path == workspace.root
    if not hasRoot:
      return false
  var paths = initHashSet[string]()
  var previousPath = ""
  for file in value.files:
    let path = canonicalPath(file.path)
    if path != file.path or not validBootstrapPath(workspace.root, path) or path in paths or
        (previousPath.len > 0 and path <= previousPath) or file.byteLength < 0 or
        file.stamp.size < 0 or file.stamp.modifiedNanoseconds < -1 or
        file.stamp.modifiedNanoseconds >= 1_000_000_000:
      return false
    paths.incl path
    previousPath = path
  for file in value.files:
    var previousDependency = ""
    for dependency in file.forward:
      let normalized = canonicalPath(dependency)
      if normalized != dependency or not paths.contains(normalized) or
          (previousDependency.len > 0 and dependency <= previousDependency):
        return false
      previousDependency = dependency
  true

proc applyBootstrapDependencies(workspace: Workspace, value: BootstrapResult): bool =
  workspace.unresolved.clear()
  for file in workspace.files.mitems:
    file.reverse.setLen(0)
    if file.state != workspaceOpen:
      file.forward.setLen(0)

  for bootstrapFile in value.files:
    if not workspace.paths.hasKey(bootstrapFile.path):
      return false
    let id = workspace.paths[bootstrapFile.path]
    let index = id.recordIndex
    if index < 0 or index >= workspace.files.len:
      return false
    if workspace.files[index].state == workspaceOpen:
      workspace.replaceDependencies(id)
      continue
    for dependencyPath in bootstrapFile.forward:
      if not workspace.paths.hasKey(dependencyPath):
        return false
      addUniqueId(workspace.files[index].forward, workspace.paths[dependencyPath])
    workspace.files[index].forward.sortIds
    if bootstrapFile.unresolved:
      workspace.unresolved.incl uint32(id)

  for file in workspace.files:
    for dependency in file.forward:
      let dependencyIndex = dependency.recordIndex
      if dependencyIndex < 0 or dependencyIndex >= workspace.files.len:
        return false
      addUniqueId(workspace.files[dependencyIndex].reverse, file.id)
  for file in workspace.files.mitems:
    file.reverse.sortIds
  true

proc sameBootstrapContent(
    workspace: Workspace, file: FileRecord, bootstrapFile: BootstrapFile
): bool =
  if file.state != workspaceOnDisk:
    return false
  if file.index != nil:
    return
      file.index.contentHash == bootstrapFile.sourceHash and
      file.index.byteLength == bootstrapFile.byteLength
  if file.textLoaded:
    return
      contentFingerprint(file.text) == bootstrapFile.sourceHash and
      file.text.len == bootstrapFile.byteLength
  if workspace.manifestByPath.hasKey(file.path):
    let entry = workspace.manifestByPath[file.path]
    return
      entry.sourceHash == bootstrapFile.sourceHash and
      entry.byteLength == int64(bootstrapFile.byteLength)
  false

proc sameBootstrapDependencies(
    workspace: Workspace, id: FileId, forward: openArray[string]
): bool =
  let index = id.recordIndex
  if index < 0 or index >= workspace.files.len:
    return false
  var expected = newSeqOfCap[FileId](forward.len)
  for path in forward:
    if not workspace.paths.hasKey(path):
      return false
    expected.add workspace.paths[path]
  expected.sortIds
  if workspace.files[index].forward.len != expected.len:
    return false
  for position in 0 ..< expected.len:
    if uint32(workspace.files[index].forward[position]) != uint32(expected[position]):
      return false
  true

proc adoptWorkspaceState(destination, source: Workspace) =
  destination.root = source.root
  destination.manifest = source.manifest
  destination.bootstrapState = source.bootstrapState
  destination.bootstrapAttempt = source.bootstrapAttempt
  destination.snapshotId = source.snapshotId
  destination.configGeneration = source.configGeneration
  destination.workspaceGeneration = source.workspaceGeneration
  destination.nextFileId = source.nextFileId
  destination.nextContentGeneration = source.nextContentGeneration
  destination.surfaceGeneration = source.surfaceGeneration
  destination.files = source.files
  destination.paths = source.paths
  destination.manifestByPath = source.manifestByPath
  destination.invalidated = source.invalidated
  destination.unresolved = source.unresolved
  destination.moduleCatalogCache = source.moduleCatalogCache
  destination.projectSurfaceCache = source.projectSurfaceCache
  destination.projectSurfaceBuiltGeneration = source.projectSurfaceBuiltGeneration
  destination.projectSurfaceInputs = source.projectSurfaceInputs
  destination.projectSurfaceInputGenerations = source.projectSurfaceInputGenerations
  destination.projectSurfaceInputCandidateCounts =
    source.projectSurfaceInputCandidateCounts

proc applyBootstrap*(workspace: Workspace, value: BootstrapResult): bool =
  if workspace == nil or not workspace.validBootstrapResult(value):
    return false

  var candidate = cloneWorkspaceState(workspace)
  var present = initHashSet[string]()
  for file in value.files:
    let path = file.path
    present.incl path
    if not candidate.paths.hasKey(path):
      let id = FileId(candidate.nextFileId)
      inc candidate.nextFileId
      candidate.paths[path] = id
      candidate.files.add FileRecord(
        id: id,
        path: path,
        state: workspaceMissing,
        version: -1,
        contentGeneration: InvalidContentGeneration,
        dependencyGeneration: InvalidDependencyGeneration,
        stamp: unknownStamp(),
        forward: @[],
        reverse: @[],
      )

  var changedRoots: seq[FileId] = @[]
  for index in 0 ..< candidate.files.len:
    if candidate.files[index].state != workspaceOpen and
        not present.contains(candidate.files[index].path) and
        candidate.files[index].state != workspaceMissing:
      addUniqueId(changedRoots, candidate.files[index].id)
      candidate.files[index].state = workspaceMissing
      candidate.files[index].text = ""
      candidate.files[index].textLoaded = true
      candidate.files[index].stamp = unknownStamp()
      candidate.files[index].index = indexSource("")
      candidate.files[index].contentGeneration = candidate.nextContent()

  for file in value.files:
    let id = candidate.paths[file.path]
    let index = id.recordIndex
    if candidate.files[index].state == workspaceOpen:
      continue
    let sameContent = sameBootstrapContent(candidate, candidate.files[index], file)
    let sameGraph =
      sameBootstrapDependencies(candidate, id, file.forward) and
      ((uint32(id) in candidate.unresolved) == file.unresolved)
    if not sameContent or not sameGraph:
      addUniqueId(changedRoots, id)
    candidate.files[index].state = workspaceOnDisk
    candidate.files[index].version = -1
    candidate.files[index].text = ""
    candidate.files[index].textLoaded = false
    candidate.files[index].stamp = file.stamp
    if not sameContent:
      candidate.files[index].index = nil
      candidate.files[index].contentGeneration = candidate.nextContent()

  if changedRoots.len > 0:
    candidate.moduleCatalogCache = nil
    candidate.invalidateProjectSurface()
  candidate.manifest = bootstrapManifest(value)
  candidate.manifestByPath.clear()
  for entry in candidate.manifest.entries:
    candidate.manifestByPath[entry.path] = entry
  candidate.bootstrapState = workspaceBootstrapComplete
  candidate.bootstrapAttempt = ConfigGeneration(value.configGeneration)
  try:
    if not candidate.applyBootstrapDependencies(value):
      return false
    candidate.invalidated.setLen(0)
    if changedRoots.len > 0:
      var affected: seq[FileId] = @[]
      for root in changedRoots:
        for id in workspace.reverseClosure(root):
          addUniqueId(affected, id)
        for id in candidate.reverseClosure(root):
          addUniqueId(affected, id)
      candidate.bumpSnapshot()
      for id in affected:
        let index = id.recordIndex
        if index >= 0 and index < candidate.files.len:
          candidate.files[index].dependencyGeneration =
            DependencyGeneration(uint64(candidate.snapshotId))
          addUniqueId(candidate.invalidated, id)
      sortIds(candidate.invalidated)
  except CatchableError:
    return false

  let hasOpenDocuments = block:
    var found = false
    for file in candidate.files:
      if file.state == workspaceOpen:
        found = true
        break
    found
  adoptWorkspaceState(workspace, candidate)
  if not hasOpenDocuments:
    workspace.persistManifest()
  true

proc resolveReference(workspace: Workspace, ownerPath, reference: string): FileId =
  let resolution = workspace.moduleCatalog().resolve(ownerPath, reference)
  if resolution.kind == moduleResolved: resolution.id else: InvalidFileId

proc resolveModule*(workspace: Workspace, owner: FileId, reference: string): FileId =
  let index = owner.recordIndex
  if index < 0 or index >= workspace.files.len or
      workspace.files[index].state == workspaceMissing:
    return InvalidFileId
  workspace.resolveReference(workspace.files[index].path, reference)

proc replaceDependencies(workspace: Workspace, id: FileId) =
  let index = id.recordIndex
  if index < 0 or index >= workspace.files.len:
    return

  let oldForward = workspace.files[index].forward
  for dependency in oldForward:
    let dependencyIndex = dependency.recordIndex
    if dependencyIndex >= 0 and dependencyIndex < workspace.files.len:
      removeId(workspace.files[dependencyIndex].reverse, id)

  workspace.files[index].forward.setLen(0)
  var unresolved = false
  if workspace.files[index].index != nil:
    for reference in workspace.files[index].index.imports:
      let dependency =
        resolveReference(workspace, workspace.files[index].path, reference)
      if dependency.valid:
        addUniqueId(workspace.files[index].forward, dependency)
      elif not reference.startsWith("std/") and reference != "std":
        unresolved = true
    for reference in workspace.files[index].index.includes:
      let dependency =
        resolveReference(workspace, workspace.files[index].path, reference)
      if dependency.valid:
        addUniqueId(workspace.files[index].forward, dependency)
      else:
        unresolved = true

  sortIds(workspace.files[index].forward)
  for dependency in workspace.files[index].forward:
    let dependencyIndex = dependency.recordIndex
    if dependencyIndex >= 0 and dependencyIndex < workspace.files.len:
      addUniqueId(workspace.files[dependencyIndex].reverse, id)
      sortIds(workspace.files[dependencyIndex].reverse)

  let fileId = uint32(workspace.files[index].id)
  if unresolved:
    workspace.unresolved.incl fileId
  else:
    workspace.unresolved.excl fileId

proc rebuildDependencies(workspace: Workspace) =
  workspace.unresolved.clear()
  for file in workspace.files.mitems:
    file.forward.setLen(0)
    file.reverse.setLen(0)
  for index in 0 ..< workspace.files.len:
    replaceDependencies(workspace, workspace.files[index].id)

proc restoreDependencies(workspace: Workspace, mode = restoreIndexed): bool =
  if not workspace.manifest.graphValid or
      workspace.manifest.entries.len != workspace.files.len:
    return false

  var seen = newSeq[bool](workspace.files.len)
  var idsByOrdinal = newSeq[FileId](workspace.manifest.entries.len)
  workspace.unresolved.clear()
  for ordinal, entry in workspace.manifest.entries:
    if not workspace.paths.hasKey(entry.path):
      return false
    let id = workspace.paths[entry.path]
    let index = id.recordIndex
    if index < 0 or index >= workspace.files.len or seen[index] or entry.byteLength < 0 or
        entry.byteLength > int64(high(int)) or
        workspace.files[index].state != workspaceOnDisk or
        (mode == restoreIndexed and workspace.files[index].index == nil) or
        not sameFileStamp(workspace.files[index].stamp, entry.stamp):
      return false
    if workspace.files[index].index != nil and (
      workspace.files[index].index.contentHash != entry.sourceHash or
      workspace.files[index].index.byteLength != int(entry.byteLength)
    ):
      return false
    seen[index] = true
    idsByOrdinal[ordinal] = id
    if entry.unresolved:
      workspace.unresolved.incl uint32(id)

  for index in 0 ..< workspace.files.len:
    if not seen[index]:
      return false
    workspace.files[index].forward = @[]
  for ordinal, entry in workspace.manifest.entries:
    let index = idsByOrdinal[ordinal].recordIndex
    var previousOrdinal = uint32(0)
    for dependencyOrdinal in entry.forwardOrdinals:
      if dependencyOrdinal >= uint32(idsByOrdinal.len) or (
        workspace.files[index].forward.len > 0 and dependencyOrdinal <= previousOrdinal
      ):
        return false
      let dependency = idsByOrdinal[int(dependencyOrdinal)]
      let dependencyIndex = dependency.recordIndex
      if dependencyIndex < 0 or dependencyIndex >= workspace.files.len or
          workspace.files[dependencyIndex].state == workspaceMissing:
        return false
      workspace.files[index].forward.add dependency
      previousOrdinal = dependencyOrdinal

  for index in 0 ..< workspace.files.len:
    workspace.files[index].reverse.setLen(0)
  for index in 0 ..< workspace.files.len:
    for dependency in workspace.files[index].forward:
      let dependencyIndex = dependency.recordIndex
      if dependencyIndex < 0 or dependencyIndex >= workspace.files.len:
        return false
      addUniqueId(workspace.files[dependencyIndex].reverse, workspace.files[index].id)
  for file in workspace.files.mitems:
    file.forward.sortIds
    file.reverse.sortIds
  true

proc reverseClosure(workspace: Workspace, root: FileId): seq[FileId] =
  if not root.valid:
    return
  var seen = newSeq[bool](workspace.files.len)
  var queue = @[root]
  var head = 0
  while head < queue.len:
    let current = queue[head]
    inc head
    let index = current.recordIndex
    if index < 0 or index >= workspace.files.len or seen[index]:
      continue
    seen[index] = true
    result.add current
    for dependent in workspace.files[index].reverse:
      queue.add dependent
  result.sortIds

proc invalidateDependents(
    workspace: Workspace, root: FileId, kind = invalidationContent
): seq[FileId] =
  result = reverseClosure(workspace, root)
  case kind
  of invalidationContent:
    discard
  of invalidationTopology:
    for unresolvedId in workspace.unresolved:
      for dependent in reverseClosure(workspace, FileId(unresolvedId)):
        addUniqueId(result, dependent)
  if result.len == 0:
    return
  workspace.bumpSnapshot()
  for id in result:
    let index = id.recordIndex
    workspace.files[index].dependencyGeneration =
      DependencyGeneration(uint64(workspace.snapshotId))
    addUniqueId(workspace.invalidated, id)
  sortIds(workspace.invalidated)

proc invalidateAll(workspace: Workspace) =
  workspace.bumpSnapshot()
  for file in workspace.files.mitems:
    file.dependencyGeneration = DependencyGeneration(uint64(workspace.snapshotId))
    addUniqueId(workspace.invalidated, file.id)
  sortIds(workspace.invalidated)

proc installText(
    workspace: Workspace,
    id: FileId,
    text: string,
    state: WorkspaceFileState,
    version: int64,
    invalidate: bool,
): bool =
  let index = id.recordIndex
  if index < 0 or index >= workspace.files.len:
    return false
  if workspace.files[index].state == workspaceOpen and version >= 0 and
      workspace.files[index].version >= 0 and version <= workspace.files[index].version:
    return false
  let previousText = workspace.files[index].text
  let previousIndex = workspace.files[index].index
  let stateChanged = workspace.files[index].state != state

  let changed =
    if workspace.files[index].textLoaded:
      workspace.files[index].index == nil or workspace.files[index].text != text
    else:
      workspace.files[index].index == nil or
        workspace.files[index].index.contentHash != contentFingerprint(text) or
        workspace.files[index].index.byteLength != text.len
  workspace.files[index].state = state
  if version >= 0 or state != workspaceOpen or workspace.files[index].version < 0:
    workspace.files[index].version = version
  workspace.files[index].text = text
  workspace.files[index].textLoaded = true
  workspace.files[index].stamp =
    if state == workspaceOnDisk:
      fileStamp(workspace.files[index].path)
    else:
      unknownStamp()
  if not changed:
    if stateChanged:
      workspace.moduleCatalogCache = nil
      workspace.invalidateProjectSurface()
    return true

  if stateChanged:
    workspace.moduleCatalogCache = nil
  workspace.invalidateProjectSurface()
  if invalidate:
    discard invalidateDependents(workspace, id)
  workspace.files[index].index =
    if state == workspaceOnDisk:
      workspace.indexDiskSource(workspace.files[index].path, text)
    elif state == workspaceOpen:
      let incremental = tryIndexSourceIncremental(previousText, previousIndex, text)
      if incremental != nil:
        incremental
      else:
        indexSource(text)
    else:
      indexSource(text)
  workspace.files[index].contentGeneration = workspace.nextContent()
  replaceDependencies(workspace, id)
  true

proc installDiskText(
    workspace: Workspace, id: FileId, source: string, stamp: FileStamp, invalidate: bool
): bool =
  result = installText(workspace, id, source, workspaceOnDisk, -1, invalidate)
  if result:
    workspace.files[id.recordIndex].stamp = stamp

proc stableDiskSource(
    path: string
): tuple[valid: bool, source: string, stamp: FileStamp] =
  for _ in 0 .. 1:
    let before = fileStamp(path)
    if before.size < 0:
      return
    try:
      let source = readFile(path)
      let after = fileStamp(path)
      if sameFileStamp(before, after) and after.size == int64(source.len):
        return (true, source, after)
    except CatchableError:
      return

proc cachedManifestIndex(
    workspace: Workspace, id: FileId, stamp: FileStamp
): SourceIndex =
  let index = id.recordIndex
  if index < 0 or index >= workspace.files.len or
      workspace.files[index].state != workspaceOnDisk or
      not workspace.manifestByPath.hasKey(workspace.files[index].path):
    return
  let path = workspace.files[index].path
  let entry = workspace.manifestByPath[path]
  if entry.byteLength < 0 or entry.byteLength > int64(high(int)) or
      entry.byteLength != stamp.size:
    return
  loadCachedSourceIndexFingerprint(
    workspace.root, path, entry.sourceHash, int(entry.byteLength)
  )

proc ensureText(workspace: Workspace, id: FileId, invalidate = true): bool =
  let index = id.recordIndex
  if index < 0 or index >= workspace.files.len:
    return false
  if workspace.files[index].state == workspaceOpen:
    return workspace.files[index].textLoaded

  let path = workspace.files[index].path
  let currentStamp = fileStamp(path)
  if currentStamp.size < 0:
    if workspace.files[index].state != workspaceMissing:
      discard installText(workspace, id, "", workspaceMissing, -1, invalidate)
      workspace.persistManifest()
    return false
  if workspace.files[index].state == workspaceOnDisk and
      workspace.files[index].textLoaded and
      sameFileStamp(currentStamp, workspace.files[index].stamp):
    return true
  if workspace.files[index].state == workspaceOnDisk and
      workspace.files[index].index == nil:
    workspace.files[index].index = workspace.cachedManifestIndex(id, currentStamp)

  let stable = stableDiskSource(path)
  if not stable.valid:
    discard installText(workspace, id, "", workspaceMissing, -1, invalidate)
    workspace.persistManifest()
    return false
  let sourceHash = contentFingerprint(stable.source)
  if workspace.files[index].state == workspaceOnDisk and
      workspace.files[index].index != nil and
      workspace.files[index].index.contentHash == sourceHash and
      workspace.files[index].index.byteLength == stable.source.len:
    workspace.files[index].text = stable.source
    workspace.files[index].textLoaded = true
    workspace.files[index].stamp = stable.stamp
    return true
  let wasMissing = workspace.files[index].state == workspaceMissing
  discard workspace.installDiskText(id, stable.source, stable.stamp, invalidate)
  if wasMissing:
    workspace.rebuildDependencies()
    discard workspace.invalidateDependents(id, invalidationTopology)
  workspace.persistManifest()
  true

proc ensureIndex(workspace: Workspace, id: FileId): bool =
  let index = id.recordIndex
  if index < 0 or index >= workspace.files.len:
    return false
  if workspace.files[index].state == workspaceMissing:
    return false
  if workspace.files[index].index != nil:
    return true
  if workspace.files[index].state == workspaceOpen:
    discard workspace.ensureText(id)
    return workspace.files[index].index != nil

  let path = workspace.files[index].path
  let currentStamp = fileStamp(path)
  if currentStamp.size < 0:
    discard workspace.ensureText(id)
    return false
  if workspace.files[index].state != workspaceOnDisk or
      not sameFileStamp(currentStamp, workspace.files[index].stamp):
    discard workspace.ensureText(id)
    return workspace.files[index].index != nil

  let cached = workspace.cachedManifestIndex(id, currentStamp)
  if cached != nil:
    workspace.files[index].index = cached
    return true

  if workspace.manifestByPath.hasKey(path):
    let entry = workspace.manifestByPath[path]
    if entry.byteLength == currentStamp.size and entry.byteLength <= int64(high(int)):
      let stable = stableDiskSource(path)
      if stable.valid and sameFileStamp(stable.stamp, currentStamp) and
          stable.source.len == int(entry.byteLength) and
          contentFingerprint(stable.source) == entry.sourceHash:
        workspace.files[index].index = indexSource(stable.source)
        discard saveCachedSourceIndex(
          workspace.root, path, stable.source, workspace.files[index].index
        )
        return true

  discard workspace.ensureText(id)
  workspace.files[index].index != nil

proc indexWorkspaceImpl(workspace: Workspace): bool =
  if workspace.root.len == 0 or not dirExists(workspace.root):
    return false

  let hadRecords = workspace.files.len > 0
  let discovered = discoverSources(workspace.root, workspace.manifest)
  if discovered.status != discoveryComplete:
    return false
  let paths = discovered.paths

  var present = initTable[string, bool]()
  var topologyChanged = false
  for path in paths:
    present[path] = true
    let ensured = ensureRecord(workspace, path)
    if hadRecords and ensured.created:
      topologyChanged = true
    elif hadRecords and workspace.files[ensured.id.recordIndex].state == workspaceMissing:
      topologyChanged = true

  for index in 0 ..< workspace.files.len:
    if workspace.files[index].state != workspaceOpen and
        not present.hasKey(workspace.files[index].path) and
        workspace.files[index].state != workspaceMissing:
      workspace.files[index].state = workspaceMissing
      workspace.files[index].text = ""
      workspace.files[index].textLoaded = true
      workspace.files[index].stamp = unknownStamp()
      workspace.files[index].index = indexSource("")
      workspace.files[index].contentGeneration = workspace.nextContent()
      if hadRecords:
        topologyChanged = true

  var lazyRestored =
    not topologyChanged and workspace.manifest.graphValid and
    workspace.manifest.entries.len == workspace.files.len and
    paths.len == workspace.files.len
  if lazyRestored:
    for path in paths:
      let id = workspace.paths[path]
      let index = id.recordIndex
      if index < 0 or index >= workspace.files.len or
          workspace.files[index].state == workspaceOpen or
          not workspace.manifestByPath.hasKey(path):
        lazyRestored = false
        break
      let entry = workspace.manifestByPath[path]
      let stamp = fileStamp(path)
      if entry.byteLength < 0 or entry.byteLength > int64(high(int)) or
          stamp.size != entry.byteLength or not sameFileStamp(stamp, entry.stamp):
        lazyRestored = false
        break
    if lazyRestored:
      for path in paths:
        let id = workspace.paths[path]
        let index = id.recordIndex
        let entry = workspace.manifestByPath[path]
        let sameContent =
          workspace.files[index].state == workspaceOnDisk and
          workspace.files[index].index != nil and
          workspace.files[index].index.contentHash == entry.sourceHash and
          workspace.files[index].index.byteLength == int(entry.byteLength)
        workspace.files[index].state = workspaceOnDisk
        workspace.files[index].version = -1
        workspace.files[index].text = ""
        workspace.files[index].textLoaded = false
        workspace.files[index].stamp = entry.stamp
        if not sameContent:
          workspace.files[index].index = nil
          workspace.files[index].contentGeneration = workspace.nextContent()
      lazyRestored = workspace.restoreDependencies(restoreLazy)

  for path in paths:
    let id = workspace.paths[path]
    if lazyRestored:
      continue
    if workspace.files[id.recordIndex].state == workspaceOpen:
      continue
    let wasMissing = workspace.files[id.recordIndex].state == workspaceMissing
    let stamp = fileStamp(path)
    if workspace.manifestByPath.hasKey(path):
      let entry = workspace.manifestByPath[path]
      if stamp.size == entry.byteLength and sameFileStamp(stamp, entry.stamp) and
          entry.byteLength <= int64(high(int)):
        let cached = loadCachedSourceIndexFingerprint(
          workspace.root, path, entry.sourceHash, int(entry.byteLength)
        )
        if cached != nil:
          let sameContent =
            workspace.files[id.recordIndex].state == workspaceOnDisk and
            workspace.files[id.recordIndex].index != nil and
            workspace.files[id.recordIndex].index.contentHash == entry.sourceHash and
            workspace.files[id.recordIndex].index.byteLength == int(entry.byteLength)
          workspace.files[id.recordIndex].state = workspaceOnDisk
          workspace.files[id.recordIndex].version = -1
          workspace.files[id.recordIndex].text = ""
          workspace.files[id.recordIndex].textLoaded = false
          workspace.files[id.recordIndex].stamp = stamp
          if not sameContent:
            workspace.files[id.recordIndex].index = cached
            workspace.files[id.recordIndex].contentGeneration = workspace.nextContent()
          continue
    let stable = stableDiskSource(path)
    if stable.valid:
      let indexed = workspace.indexDiskSource(path, stable.source)
      let sameContent =
        workspace.files[id.recordIndex].state == workspaceOnDisk and
        workspace.files[id.recordIndex].index != nil and indexed != nil and
        workspace.files[id.recordIndex].index.contentHash == indexed.contentHash and
        workspace.files[id.recordIndex].index.byteLength == indexed.byteLength
      workspace.files[id.recordIndex].text = stable.source
      workspace.files[id.recordIndex].textLoaded = true
      workspace.files[id.recordIndex].state = workspaceOnDisk
      workspace.files[id.recordIndex].version = -1
      workspace.files[id.recordIndex].stamp = stable.stamp
      if not sameContent:
        workspace.files[id.recordIndex].index = indexed
        workspace.files[id.recordIndex].contentGeneration = workspace.nextContent()
      workspace.files[id.recordIndex].text = ""
      workspace.files[id.recordIndex].textLoaded = false
      if hadRecords and wasMissing:
        topologyChanged = true
    else:
      workspace.files[id.recordIndex].state = workspaceMissing
      workspace.files[id.recordIndex].text = ""
      workspace.files[id.recordIndex].textLoaded = true
      workspace.files[id.recordIndex].stamp = unknownStamp()
      workspace.files[id.recordIndex].index = indexSource("")
      if hadRecords and not wasMissing:
        topologyChanged = true
  workspace.moduleCatalogCache = nil
  var restored = lazyRestored
  if not restored:
    restored = not topologyChanged and workspace.restoreDependencies()
  if not restored:
    rebuildDependencies(workspace)
  if topologyChanged:
    workspace.invalidateAll()
  else:
    workspace.bumpSnapshot()
  workspace.invalidateProjectSurface()
  let directoriesChanged =
    workspace.manifest.directories != discovered.directories or
    not workspace.manifest.discoveryValid
  workspace.bootstrapState = workspaceBootstrapComplete
  workspace.manifest.directories = discovered.directories
  workspace.manifest.discoveryValid = true
  if not lazyRestored or directoriesChanged:
    workspace.persistManifest()
  true

proc indexWorkspace*(workspace: Workspace, root = "") =
  if root.len > 0 and not workspace.prepareWorkspace(root):
    return
  workspace.bootstrapState = workspaceBootstrapIncomplete
  discard workspace.indexWorkspaceImpl()

proc bootstrapWorkspace*(workspace: Workspace): bool =
  case workspace.bootstrapState
  of workspaceBootstrapComplete:
    return true
  of workspaceBootstrapFailed:
    if workspace.bootstrapAttempt.value == workspace.configGeneration.value:
      return false
    workspace.bootstrapState = workspaceBootstrapIncomplete
  of workspaceBootstrapPending, workspaceBootstrapIncomplete:
    discard
  if workspace.root.len == 0 or not dirExists(workspace.root):
    workspace.bootstrapState = workspaceBootstrapFailed
    return false
  workspace.bootstrapState = workspaceBootstrapFailed
  workspace.bootstrapAttempt = workspace.configGeneration
  try:
    result = workspace.indexWorkspaceImpl()
  except CatchableError:
    result = false
    workspace.bootstrapState = workspaceBootstrapFailed

proc fileIdForPath*(workspace: Workspace, path: string): FileId =
  let key = canonicalPath(path)
  if key.len > 0 and workspace.paths.hasKey(key):
    workspace.paths[key]
  else:
    InvalidFileId

proc isOpenDocument*(workspace: Workspace, path: string): bool =
  let id = workspace.fileIdForPath(path)
  id.valid and workspace.files[id.recordIndex].state == workspaceOpen

proc fileCount*(workspace: Workspace): int =
  workspace.files.len

proc fileIds*(workspace: Workspace): seq[FileId] =
  if workspace == nil:
    return
  result = newSeqOfCap[FileId](workspace.files.len)
  for file in workspace.files:
    if file.state != workspaceMissing:
      result.add file.id

proc dependencies*(workspace: Workspace, id: FileId): seq[FileId] =
  let index = id.recordIndex
  if index >= 0 and index < workspace.files.len:
    result = newSeqOfCap[FileId](workspace.files[index].forward.len)
    for dependency in workspace.files[index].forward:
      result.add dependency

proc dependents*(workspace: Workspace, id: FileId): seq[FileId] =
  let index = id.recordIndex
  if index >= 0 and index < workspace.files.len:
    result = newSeqOfCap[FileId](workspace.files[index].reverse.len)
    for dependent in workspace.files[index].reverse:
      result.add dependent

proc graphComplete*(workspace: Workspace): bool =
  workspace.bootstrapState == workspaceBootstrapComplete and
    workspace.unresolved.len == 0 and workspace.moduleCatalog().complete()

proc workspaceGeneration*(workspace: Workspace): uint64 =
  if workspace == nil: 0 else: workspace.workspaceGeneration

proc configurationGeneration*(workspace: Workspace): uint64 =
  if workspace == nil:
    0
  else:
    uint64(workspace.configGeneration)

proc openDocumentIds*(workspace: Workspace): seq[FileId] =
  if workspace == nil:
    return
  for file in workspace.files:
    if file.state == workspaceOpen:
      result.add file.id

proc drainInvalidated*(workspace: Workspace): seq[FileId] =
  result = newSeqOfCap[FileId](workspace.invalidated.len)
  for id in workspace.invalidated:
    result.add id
  workspace.invalidated = @[]

proc openDocument*(
    workspace: Workspace, uri, path, text: string, version: int64
): FileId =
  workspace.bumpWorkspaceGeneration()
  let ensured = ensureRecord(workspace, path)
  result = ensured.id
  if not result.valid:
    return
  workspace.files[result.recordIndex].uri = uri
  if not installText(workspace, result, text, workspaceOpen, version, true):
    return
  if ensured.created:
    rebuildDependencies(workspace)
    discard workspace.invalidateDependents(result, invalidationTopology)

proc changeDocument*(
    workspace: Workspace, uri, path, text: string, version: int64
): bool =
  let known = workspace.fileIdForPath(path)
  if known.valid:
    let index = known.recordIndex
    if workspace.files[index].state == workspaceOpen and version >= 0 and
        workspace.files[index].version >= 0 and version <= workspace.files[index].version:
      return false
  workspace.bumpWorkspaceGeneration()
  let ensured = ensureRecord(workspace, path)
  if not ensured.id.valid:
    return false
  workspace.files[ensured.id.recordIndex].uri = uri
  result = installText(workspace, ensured.id, text, workspaceOpen, version, true)
  if ensured.created:
    rebuildDependencies(workspace)
    discard workspace.invalidateDependents(ensured.id, invalidationTopology)

proc refreshDiskFile*(workspace: Workspace, path: string, deleted = false) =
  workspace.bumpWorkspaceGeneration()
  let ensured = ensureRecord(workspace, path)
  if not ensured.id.valid:
    return
  let index = ensured.id.recordIndex
  if workspace.files[index].state == workspaceOpen:
    return
  let wasMissing = workspace.files[index].state == workspaceMissing
  var topologyChanged = ensured.created or wasMissing
  if deleted or not fileExists(workspace.files[index].path):
    discard installText(workspace, ensured.id, "", workspaceMissing, -1, true)
    topologyChanged = not wasMissing
  else:
    let stable = stableDiskSource(workspace.files[index].path)
    if stable.valid:
      discard workspace.installDiskText(ensured.id, stable.source, stable.stamp, true)
    else:
      discard installText(workspace, ensured.id, "", workspaceMissing, -1, true)
      topologyChanged = not wasMissing
  if topologyChanged:
    workspace.moduleCatalogCache = nil
    rebuildDependencies(workspace)
    discard workspace.invalidateDependents(ensured.id, invalidationTopology)
  workspace.persistManifest()

proc closeDocument*(workspace: Workspace, uri, path: string) =
  workspace.bumpWorkspaceGeneration()
  let id = workspace.fileIdForPath(path)
  if not id.valid:
    return
  let index = id.recordIndex
  workspace.files[index].uri = uri
  let stable = stableDiskSource(workspace.files[index].path)
  if stable.valid:
    discard workspace.installDiskText(id, stable.source, stable.stamp, true)
  else:
    discard installText(workspace, id, "", workspaceMissing, -1, true)
    rebuildDependencies(workspace)
  workspace.persistManifest()

proc configurationChanged*(workspace: Workspace) =
  workspace.bumpWorkspaceGeneration()
  workspace.configGeneration =
    ConfigGeneration(uint64(workspace.configGeneration) + 1'u64)
  workspace.moduleCatalogCache = nil
  workspace.rebuildDependencies()
  workspace.invalidateProjectSurface()
  if workspace.bootstrapState == workspaceBootstrapFailed:
    workspace.bootstrapState = workspaceBootstrapIncomplete
  invalidateAll(workspace)

proc fileChanged*(workspace: Workspace, path: string, deleted = false) =
  let lower = path.toLowerAscii
  if lower.endsWith("/nim.cfg") or lower.endsWith("/config.nims") or
      lower.endsWith(".nimble") or lower.endsWith(".cfg"):
    workspace.configurationChanged()
  elif lower.endsWith(".nim"):
    workspace.refreshDiskFile(path, deleted)

proc releaseDiskText(workspace: Workspace, index: int) =
  if workspace.files[index].state == workspaceOnDisk:
    workspace.files[index].text = ""
    workspace.files[index].textLoaded = false

proc snapshotForDocument*(workspace: Workspace, uri, path: string): WorkspaceSnapshot =
  let id = workspace.fileIdForPath(path)
  if id.valid:
    discard workspace.ensureText(id)
  else:
    let ensured = ensureRecord(workspace, path)
    if not ensured.id.valid:
      return
    if ensured.created:
      workspace.bumpWorkspaceGeneration()
    discard workspace.ensureText(ensured.id, invalidate = false)
  let current = workspace.fileIdForPath(path)
  if not current.valid:
    return
  let index = current.recordIndex
  result.valid = workspace.files[index].state != workspaceMissing
  result.id = workspace.snapshotId
  result.fileId = current
  result.path = workspace.files[index].path
  result.uri =
    if uri.len > 0:
      uri
    else:
      workspace.files[index].uri
  result.version = workspace.files[index].version
  result.text = workspace.files[index].text
  result.state = workspace.files[index].state
  result.contentGeneration = workspace.files[index].contentGeneration
  result.dependencyGeneration = workspace.files[index].dependencyGeneration
  result.configGeneration = workspace.configGeneration
  result.surfaceGeneration = workspace.surfaceGeneration
  result.index = workspace.files[index].index
  workspace.releaseDiskText(index)

proc snapshotForFile*(workspace: Workspace, id: FileId): WorkspaceSnapshot =
  let index = id.recordIndex
  if index < 0 or index >= workspace.files.len:
    return
  discard workspace.ensureText(id)
  result.valid = workspace.files[index].state != workspaceMissing
  result.id = workspace.snapshotId
  result.fileId = id
  result.path = workspace.files[index].path
  result.uri = workspace.files[index].uri
  result.version = workspace.files[index].version
  result.text = workspace.files[index].text
  result.state = workspace.files[index].state
  result.contentGeneration = workspace.files[index].contentGeneration
  result.dependencyGeneration = workspace.files[index].dependencyGeneration
  result.configGeneration = workspace.configGeneration
  result.surfaceGeneration = workspace.surfaceGeneration
  result.index = workspace.files[index].index
  workspace.releaseDiskText(index)

proc indexViewForFile*(workspace: Workspace, id: FileId): WorkspaceIndexView =
  let index = id.recordIndex
  if index < 0 or index >= workspace.files.len:
    return
  discard workspace.ensureIndex(id)
  result.valid = workspace.files[index].state != workspaceMissing
  result.id = workspace.snapshotId
  result.fileId = id
  result.path = workspace.files[index].path
  result.uri = workspace.files[index].uri
  result.contentGeneration = workspace.files[index].contentGeneration
  result.index = workspace.files[index].index

proc moduleForPath*(workspace: Workspace, path: string): string =
  workspace.moduleCatalog().moduleForPath(path)

proc projectSurface*(workspace: Workspace): SurfaceIndex =
  if workspace == nil:
    return
  if workspace.projectSurfaceCache != nil and
      workspace.projectSurfaceBuiltGeneration.value == workspace.surfaceGeneration.value:
    return workspace.projectSurfaceCache
  let catalog = workspace.moduleCatalog()
  let universeComplete = workspace.graphComplete()
  workspace.projectSurfaceInputs.setLen(workspace.files.len)
  workspace.projectSurfaceInputGenerations.setLen(workspace.files.len)
  workspace.projectSurfaceInputCandidateCounts.setLen(workspace.files.len)
  var contributors = newSeqOfCap[SurfaceContributor](workspace.files.len)
  for file in workspace.files:
    let fileIndex = file.id.recordIndex
    if fileIndex < 0 or fileIndex >= workspace.files.len or
        file.state == workspaceMissing or not workspace.ensureIndex(file.id):
      if fileIndex >= 0 and fileIndex < workspace.projectSurfaceInputs.len:
        workspace.projectSurfaceInputs[fileIndex] = SurfaceInput()
        workspace.projectSurfaceInputGenerations[fileIndex] = 0
        workspace.projectSurfaceInputCandidateCounts[fileIndex] = 0
      continue
    let module = catalog.moduleForPath(file.path)
    if module.len == 0:
      workspace.projectSurfaceInputs[fileIndex] = SurfaceInput()
      workspace.projectSurfaceInputGenerations[fileIndex] = 0
      workspace.projectSurfaceInputCandidateCounts[fileIndex] = 0
      continue
    let candidateCount = uint32(catalog.candidateCount(module))
    let contentGeneration = uint64(workspace.files[fileIndex].contentGeneration)
    var input = workspace.projectSurfaceInputs[fileIndex]
    if contentGeneration != workspace.projectSurfaceInputGenerations[fileIndex] or
        input.module != module or
        candidateCount != workspace.projectSurfaceInputCandidateCounts[fileIndex]:
      input = projectSurfaceInput(module, workspace.files[fileIndex].index)
      workspace.projectSurfaceInputs[fileIndex] = input
      workspace.projectSurfaceInputGenerations[fileIndex] = contentGeneration
      workspace.projectSurfaceInputCandidateCounts[fileIndex] = candidateCount
    if candidateCount > 1:
      input.uncertainty.incl surfaceUnsupported
    contributors.add SurfaceContributor(
      fileId: file.id,
      contentGeneration: workspace.files[fileIndex].contentGeneration,
      input: input,
    )
  workspace.projectSurfaceCache = buildProjectSurfaceIndex(
    contributors, universeComplete, workspace.projectSurfaceCache
  )
  workspace.projectSurfaceBuiltGeneration = workspace.surfaceGeneration
  workspace.projectSurfaceCache
