import ../index/surface_project_input
import ../index/surfaces
import ./module_catalog
import ./paths
import ./workspace_file_ids
import ./workspace_models

proc cachedProjectSurfaceContributor*(
    root: string,
    file: FileRecord,
    catalog: ModuleCatalog,
    inputs: var seq[SurfaceInput],
    generations: var seq[uint64],
    candidateCounts: var seq[uint32],
): tuple[hasModule: bool, contributor: SurfaceContributor] =
  let fileIndex = file.id.recordIndex
  let module = catalog.moduleForPath(file.path)
  if module.len == 0:
    inputs[fileIndex] = SurfaceInput()
    generations[fileIndex] = 0
    candidateCounts[fileIndex] = 0
    return

  let candidateCount = uint32(catalog.candidateCount(module))
  let contentGeneration = uint64(file.contentGeneration)
  var input = inputs[fileIndex]
  if contentGeneration != generations[fileIndex] or input.module != module or
      candidateCount != candidateCounts[fileIndex]:
    let origin = if pathWithin(root, file.path): surfaceProject else: surfaceExternal
    input = projectSurfaceInput(module, file.index, origin)
    inputs[fileIndex] = input
    generations[fileIndex] = contentGeneration
    candidateCounts[fileIndex] = candidateCount
  if candidateCount > 1:
    input.uncertainty.incl surfaceUnsupported
  result.hasModule = true
  result.contributor = SurfaceContributor(
    fileId: file.id, contentGeneration: file.contentGeneration, input: input
  )
