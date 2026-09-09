import std/[sets, tables]

import ../index/cache
import ./ids
import ./workspace_invalidation
import ./workspace_manifest_persistence
import ./workspace_models

proc finalizeWorkspaceIndex*(
    root: string,
    bootstrapState: var WorkspaceBootstrapState,
    manifest: var ProjectManifest,
    manifestByPath: var Table[string, ManifestEntry],
    files: var seq[FileRecord],
    paths: Table[string, FileId],
    unresolved: HashSet[uint32],
    invalidated: var seq[FileId],
    snapshotId: var SnapshotId,
    surfaceGeneration: var SurfaceGeneration,
    directories: seq[ManifestDirectory],
    topologyChanged, lazyRestored: bool,
) =
  if topologyChanged:
    invalidateAll(files, invalidated, snapshotId)
  else:
    bumpSnapshot(snapshotId)
  invalidateProjectSurface(surfaceGeneration)
  let directoriesChanged =
    manifest.directories != directories or not manifest.discoveryValid
  bootstrapState = workspaceBootstrapComplete
  manifest.directories = directories
  manifest.discoveryValid = true
  if not lazyRestored or directoriesChanged:
    persistManifest(
      bootstrapState, root, manifest, manifestByPath, surfaceGeneration, files, paths,
      unresolved,
    )
