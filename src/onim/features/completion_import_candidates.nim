import std/[sets, tables]

import ./completion_candidates
import ./completion_imports
import ./completion_stdlib_module
import ../index/surface_project_input
import ../index/surface_resolution
import ../index/surfaces
import ../index/source_index
import ../session/module_catalog
import ../session/ids
import ../session/workspace
import ../session/workspace_models
import ../stdlib/map
import ../syntax/imports
import ../syntax/module_names
import ../syntax/tokens

proc appendProjectImport*(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    item: ImportInfo,
    owner: string,
    catalog: ModuleCatalog,
    prefixKey: string,
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
    importedProviders: var Table[string, string],
    ambiguousNames: var HashSet[string],
): bool =
  if catalog == nil or not catalog.complete or not workspace.graphComplete:
    return true
  let project = catalog.resolveModuleName(owner, item.module)
  if project.kind != moduleResolved:
    return true
  let view = workspace.indexViewForFile(project.id)
  if not view.valid or view.index == nil or view.id.value != source.id.value or
      not view.index.nativeIndexSafe():
    return true
  let input = projectSurfaceInput(project.module, view.index)
  if input.module.len == 0 or input.uncertainty != {}:
    return true
  let selection = source.importedSelection(item)
  if selection.kind == importedSelectionSkip:
    return true
  for exported in input.exports:
    if not exported.kindKnown:
      continue
    if selection.kind == importedSelectionAll and item.excludedImportName(exported.name):
      continue
    let localName = selection.selectedImportedName(exported.name)
    if localName.len == 0:
      continue
    discard appendImportedCandidate(
      localName,
      canonicalModule(project.module) & "|" & identifierKey(exported.name),
      memberCompletionKind(exported.kind),
      prefixKey,
      candidates,
      candidateByName,
      importedProviders,
      ambiguousNames,
    )
  true

proc appendStdlibImport*(
    stdlib: StdlibMap,
    source: WorkspaceSnapshot,
    item: ImportInfo,
    prefixKey: string,
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
    importedProviders: var Table[string, string],
    ambiguousNames: var HashSet[string],
): bool =
  let module = stdlib.stdlibModuleName(item.module)
  if module.len == 0:
    return true
  let selection = source.importedSelection(item)
  if selection.kind == importedSelectionSkip:
    return true
  let surface = stdlib.surfaceIndex()
  var bindings: seq[BindingCandidate] = @[]
  if not surface.appendBindingsInModule(module, "", bindings):
    return true
  for binding in bindings:
    let exports = surface.exportsFor(binding)
    if exports.len == 0:
      continue
    if selection.kind == importedSelectionAll and item.excludedImportName(binding.name):
      continue
    let localName = selection.selectedImportedName(binding.name)
    if localName.len == 0:
      continue
    discard appendImportedCandidate(
      localName,
      module & "|" & identifierKey(binding.name),
      memberCompletionKind(exports[0].kind),
      prefixKey,
      candidates,
      candidateByName,
      importedProviders,
      ambiguousNames,
    )
  true
