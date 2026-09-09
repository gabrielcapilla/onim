import std/strutils

import ../session/module_catalog
import ../syntax/tokens
import ./surfaces

proc appendBindingsInModule*(
    index: SurfaceIndex, module, prefix: string, destination: var seq[BindingCandidate]
): bool =
  if index == nil or not index.valid or not index.universeIsComplete:
    return false
  let canonical = canonicalSurfaceModule(module)
  let surfaceId = index.surfaceIdForModule(canonical)
  if canonical.len == 0 or uint32(surfaceId) == 0:
    return false
  let surface = index.moduleAt(surfaceId)
  if surface.uncertainty != {}:
    return false
  let wanted = identifierKey(prefix)
  let first = int(surface.firstBinding)
  let past = int(surface.pastBinding)
  if first < 0 or first > past or past > index.bindingCount:
    return false
  for ordinal in first ..< past:
    let binding = index.bindingAt(BindingId(uint32(ordinal + 1)))
    if wanted.len == 0 or binding.key.startsWith(wanted):
      destination.add binding
  true

proc exportsFor*(index: SurfaceIndex, binding: BindingCandidate): seq[ExportRecord] =
  if index == nil or binding.firstExport > binding.pastExport or
      binding.pastExport > uint32(index.exportCount):
    return
  for ordinal in int(binding.firstExport) ..< int(binding.pastExport):
    result.add index.exportAt(uint32(ordinal))

proc appendCandidates(
    index: SurfaceIndex, ids: openArray[BindingId], result: var BindingResolution
) =
  for id in ids:
    result.candidates.add index.bindingAt(id)

proc resolution(index: SurfaceIndex, ids: seq[BindingId]): BindingResolution =
  if index == nil or not index.valid:
    result.kind = surfaceUnknown
    return
  if ids.len == 0:
    result.kind = if index.universeIsComplete: surfaceUnresolved else: surfaceUnknown
    return
  if ids.len > 1:
    result.kind = surfaceAmbiguous
    index.appendCandidates(ids, result)
    return
  let candidate = index.bindingAt(ids[0])
  let surface = index.moduleAt(candidate.surface)
  index.appendCandidates(ids, result)
  if not index.universeIsComplete or surface.uncertainty != {}:
    result.kind = surfaceUnknown
  else:
    result.kind = surfaceResolved

proc lookup*(index: SurfaceIndex, name: string): BindingResolution =
  let key = identifierKey(name)
  if key.len == 0 or index == nil:
    return index.resolution(@[])
  index.resolution(index.bindingIdsForName(key))

proc lookupInModule*(index: SurfaceIndex, module, name: string): BindingResolution =
  if index == nil:
    result.kind = surfaceUnknown
    return
  let canonical = canonicalSurfaceModule(module)
  let surfaceId = index.surfaceIdForModule(canonical)
  if canonical.len == 0 or uint32(surfaceId) == 0:
    return index.resolution(@[])
  let moduleInfo = index.moduleAt(surfaceId)
  let wanted = identifierKey(name)
  var ids: seq[BindingId] = @[]
  for ordinal in int(moduleInfo.firstBinding) ..< int(moduleInfo.pastBinding):
    let binding = index.bindingAt(BindingId(uint32(ordinal + 1)))
    if binding.key == wanted:
      ids.add BindingId(uint32(ordinal + 1))
  index.resolution(ids)

proc resolveSurfaceReference*(
    index: SurfaceIndex, catalog: ModuleCatalog, name, qualifier, owner: string
): BindingResolution =
  if index == nil:
    result.kind = surfaceUnknown
    return
  if qualifier.len == 0:
    return index.lookup(name)

  if catalog != nil:
    let module = catalog.resolveModuleName(owner, qualifier)
    case module.kind
    of moduleResolved:
      return index.lookupInModule(module.module, name)
    of moduleAmbiguous, moduleUnknown:
      result.kind = surfaceUnknown
    of moduleMissing:
      result.kind = surfaceUnresolved
    return

  let module = index.moduleForReference(qualifier, owner)
  if module.len == 0:
    if index.universeIsComplete:
      result.kind = surfaceUnresolved
    else:
      result.kind = surfaceUnknown
    return
  index.lookupInModule(module, name)

proc moduleForResolution*(index: SurfaceIndex, resolution: BindingResolution): string =
  if index == nil or resolution.kind != surfaceResolved or resolution.candidates.len != 1:
    return
  index.moduleAt(resolution.candidates[0].surface).module
