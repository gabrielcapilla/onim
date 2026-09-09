import std/[algorithm, tables]

import ../index/cache
import ./bootstrap_worker
import ./paths

proc replaceManifestEntry(value: var ProjectManifest, entry: ManifestEntry) =
  value.entries.add entry

proc bootstrapManifest*(value: BootstrapResult): ProjectManifest =
  result.root = canonicalPath(value.root)
  result.graphValid = true
  result.directories = value.directories
  result.discoveryValid = value.discoveryValid
  var ordinals = initTable[string, uint32]()
  for ordinal, file in value.files:
    if pathWithin(result.root, file.path):
      ordinals[file.path] = uint32(ordinal)
    else:
      result.graphValid = false
  for file in value.files:
    if not pathWithin(result.root, file.path):
      continue
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
      else:
        result.graphValid = false
    entry.forwardOrdinals.sort
    result.replaceManifestEntry(entry)
