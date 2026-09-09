import std/[os, sets]

import ../semantic/compiler_api
import ./organize_edits
import ./organize_materialization

proc validatesEdits*(
    filePath, projectPath, source: string,
    edits: seq[ImportEdit],
    baseline: seq[CompilerDiagnostic],
    targets: HashSet[string],
    unusedTargets: HashSet[string],
): bool =
  if not editsDisjoint(edits):
    return false
  let organized = applyEdits(source, edits)
  let materialized = pathForSource(filePath, organized)
  if materialized.path.len == 0 or not fileExists(materialized.path):
    return false
  defer:
    if materialized.temporary:
      try:
        removeFile(materialized.path)
      except CatchableError:
        discard
  # Keep the original project graph while checking the edited bytes as the
  # dirty target. This avoids rebuilding a second graph for the validation
  # pass while still making the compiler inspect the proposed source.
  let after = checkFileCached(projectPath, absolutePath(materialized.path))
  var beforeNames = initHashSet[string]()
  for diagnostic in baseline:
    beforeNames.incl diagnostic.name
  for diagnostic in after:
    if diagnostic.isUnusedImport:
      if diagnostic.name in unusedTargets:
        return false
    elif diagnostic.name in targets or diagnostic.name notin beforeNames:
      return false
  true
