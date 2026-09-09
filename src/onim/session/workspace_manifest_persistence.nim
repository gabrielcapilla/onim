import std/[sets, tables]

import ../index/cache
import ./ids
import ./workspace_manifest_builder
import ./workspace_models

proc persistManifest*(
    bootstrapState: WorkspaceBootstrapState,
    root: string,
    manifest: var ProjectManifest,
    manifestByPath: var Table[string, ManifestEntry],
    surfaceGeneration: var SurfaceGeneration,
    files: openArray[FileRecord],
    paths: Table[string, FileId],
    unresolved: HashSet[uint32],
) =
  if bootstrapState != workspaceBootstrapComplete:
    return
  let candidate =
    buildManifestCandidate(root, manifest, manifestByPath, files, paths, unresolved)
  if not candidate.available:
    return
  adoptManifest(manifest, manifestByPath, surfaceGeneration, candidate.manifest)
  discard saveProjectManifestWithDiscovery(
    root, candidate.manifest.entries, candidate.manifest.graphValid,
    candidate.manifest.directories, candidate.manifest.discoveryValid,
  )
