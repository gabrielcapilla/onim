import std/[sets, tables]

import ./completion_candidates
import ../index/surfaces
import ../session/module_catalog
import ../session/workspace
import ../session/workspace_models
import ../stdlib/map

proc appendProjectAutoImports*(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    prefixKey: string,
    importedModules: openArray[string],
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
    ambiguousNames: var HashSet[string],
): bool =
  if prefixKey.len < 2 or workspace == nil or not source.valid or source.index == nil or
      workspace.moduleCatalogIfReady() == nil:
    return true
  let surface = workspace.projectSurfaceIfReady()
  if not surface.valid or not surface.universeIsComplete():
    return true
  let owner = workspace.moduleCatalogIfReady().moduleForPath(source.path)
  for moduleOrdinal in 0 ..< surface.moduleCount:
    let module = surface.moduleAt(SurfaceId(uint32(moduleOrdinal + 1)))
    if module.module.len == 0 or sameModule(module.module, owner):
      continue
    for bindingOrdinal in int(module.firstBinding) ..< int(module.pastBinding):
      let binding = surface.bindingAt(BindingId(uint32(bindingOrdinal + 1)))
      for exportOrdinal in int(binding.firstExport) ..< int(binding.pastExport):
        let exported = surface.exportAt(uint32(exportOrdinal))
        let candidate = SymbolCandidate(
          module: module.module, name: binding.name, signature: exported.signature
        )
        discard appendAutoImportCandidate(
          nil,
          candidate,
          memberCompletionKind(exported.kind),
          prefixKey,
          importedModules,
          candidates,
          candidateByName,
          ambiguousNames,
        )
  true
