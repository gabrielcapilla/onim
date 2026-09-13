import std/[os, sets, strutils]

import ../index/occurrences
import ../index/scope_validation
import ../index/source_index
import ../index/surfaces
import ../semantic/compiler_api
import ../session/module_catalog
import ../stdlib/map
import ../stdlib/map_runtime
import ../stdlib/map_resolution
import ../syntax/imports
import ../syntax/import_queries
import ../syntax/tokens
import ./organize_includes
import ./organize_materialization
import ./organize_planning
import ./organize_queries
import ./organize_removal
import ./organize_edits
import ./organize_validation
import ./organize_additions

type OrganizeOptions* = object
  useStdPrefix*: bool

proc defaultOrganizeOptions*(): OrganizeOptions =
  OrganizeOptions(useStdPrefix: true)

proc tryOrganizeSourceWithIndex*(
    filePath, source: string,
    index: SourceIndex,
    stdlib: StdlibMap,
    options = defaultOrganizeOptions(),
    project: SurfaceIndex = nil,
    catalog: ModuleCatalog = nil,
    owner: string = "",
): tuple[handled: bool, edits: seq[ImportEdit]] =
  if filePath.toLowerAscii.endsWith(".nimble") or filePath.toLowerAscii.endsWith(".cfg") or
      index == nil or index.contentHash != contentFingerprint(source) or
      index.byteLength != source.len or index.tokenCount != index.parsed.tokens.len or
      not index.scopes.validateScopes(
        index.parsed.tokens, index.symbols, index.byteLength
      ) or not index.occurrences.validateOccurrences(index.parsed.tokens) or
      not stdlib.surfaceIsComplete:
    return
  let info = index.parsed
  let nativeRemovals =
    nativeImportRemovalPlan(info, index, stdlib, project, catalog, owner)
  var removalPlan = nativeRemovals.plan
  var additions: tuple[safe: bool, candidates: seq[PlannedImport]]
  if nativeRemovals.state != nativeRemovalReady:
    if info.imports.len > 0 or index.includes.len > 0 or index.hasUnresolvedExports:
      return
    additions =
      nativeImportAdditions(source, info, index, stdlib, project, catalog, owner)
    if not additions.safe:
      return
  else:
    additions =
      nativeImportAdditions(source, info, index, stdlib, project, catalog, owner)
    if not additions.safe:
      result.handled = false
      return
  if unsafeImportInsertion(source, info, additions.candidates, stdlib):
    return
  result.handled = true
  let activeInfo = activeImportInfo(info, removalPlan)
  let newline = if source.contains("\r\n"): "\r\n" else: "\n"
  result.edits = renderImportAdditions(
    source, activeInfo, additions.candidates, stdlib, options.useStdPrefix, newline
  )
  var removals =
    unusedImportEdits(source, info, removalPlan, stdlib, options.useStdPrefix, newline)
  if additions.candidates.len == 0:
    let grouped = groupedStdRemovalEdits(
      source, info, removalPlan, stdlib, options.useStdPrefix, newline
    )
    if grouped.len > 0:
      removals = combineImportEdits(grouped, removals)
  result.edits = combineImportEdits(result.edits, removals)

proc organizeSourceImpl(
    filePath, source: string,
    info: var SourceImports,
    options = defaultOrganizeOptions(),
): seq[ImportEdit] =
  if filePath.toLowerAscii.endsWith(".nimble") or filePath.toLowerAscii.endsWith(".cfg"):
    return
  let materialized = pathForSource(filePath, source)
  if materialized.path.len == 0 or not fileExists(materialized.path):
    return
  defer:
    if materialized.temporary:
      try:
        removeFile(materialized.path)
      except CatchableError:
        discard

  var visited = initHashSet[string]()
  visited.incl absolutePath(materialized.path)
  importsAvailableFromIncluded(materialized.path, info, visited, 0)

  let projectPath = absolutePath(
    if filePath.len > 0 and fileExists(filePath): filePath else: materialized.path
  )
  let diagnostics = checkFileCached(projectPath, absolutePath(materialized.path))
  let newline = if source.contains("\r\n"): "\r\n" else: "\n"
  let unused =
    collectUnusedImportPlan(source, filePath, materialized.path, info, diagnostics)
  let removalPlan = unused.plan
  let activeInfo = activeImportInfo(info, removalPlan)
  if diagnostics.len == 0 and not hasImportRemovals(removalPlan):
    return
  let stdlib = stdlibMap()
  var newModules: seq[PlannedImport] = @[]
  var amendedFrom = initHashSet[string]()
  var seenNames = initHashSet[string]()
  var targetNames = initHashSet[string]()

  for diagnostic in diagnostics:
    if diagnostic.isUnusedImport or diagnostic.isUnusedDeclaration:
      continue
    if diagnostic.name.len == 0 or diagnostic.name in seenNames:
      continue
    seenNames.incl diagnostic.name
    let qualified = qualifiedMember(info, diagnostic)
    var name = diagnostic.name
    var qualifier = ""
    if qualified.qualifier.len > 0:
      qualifier = qualified.qualifier
      name = qualified.member
    elif info.providesName(name):
      continue
    let usageIndex = findUsageToken(info, diagnostic)
    let candidate =
      stdlib.resolveCandidate(name, qualifier, callArity(info, source, usageIndex))
    if candidate.module.len == 0:
      continue
    targetNames.incl diagnostic.name

    let existing = findExistingModule(activeInfo, candidate.module)
    if existing.plain >= 0 and qualifier.len == 0:
      continue
    if existing.plain >= 0 and qualifier.len > 0:
      continue
    if existing.aliased >= 0 or existing.excluded >= 0 or
        findFromImport(activeInfo, candidate.module, name) >= 0:
      let key = canonicalModule(candidate.module) & "|" & name
      if key notin amendedFrom:
        amendedFrom.incl key
        let fromIndex = findFromImport(activeInfo, candidate.module, name)
        if fromIndex >= 0:
          let item = activeInfo.imports[fromIndex]
          result.add ImportEdit(
            startOffset: item.endOffset, endOffset: item.endOffset, newText: ", " & name
          )
        else:
          addUniqueModule(newModules, candidate, true)
      continue
    addUniqueModule(newModules, candidate, false)

  if unsafeImportInsertion(source, info, newModules, stdlib):
    result.setLen(0)
    return

  if newModules.len > 0:
    for edit in renderImportAdditions(
      source, activeInfo, newModules, stdlib, options.useStdPrefix, newline
    ):
      result.add edit

  var removals =
    unusedImportEdits(source, info, removalPlan, stdlib, options.useStdPrefix, newline)
  if newModules.len == 0:
    let grouped = groupedStdRemovalEdits(
      source, info, removalPlan, stdlib, options.useStdPrefix, newline
    )
    if grouped.len > 0:
      removals = combineImportEdits(grouped, removals)
  result = combineImportEdits(result, removals)
  if result.len > 0 and
      not validatesEdits(
        filePath, projectPath, source, result, diagnostics, targetNames, unused.targets
      ):
    result.setLen(0)

proc organizeSourceWithImports*(
    filePath, source: string, parsed: SourceImports, options = defaultOrganizeOptions()
): seq[ImportEdit] =
  var info = cloneSourceImports(parsed)
  result = organizeSourceImpl(filePath, source, info, options)

proc organizeSource*(
    filePath, source: string, options = defaultOrganizeOptions()
): seq[ImportEdit] =
  let index = indexSource(source)
  let indexed =
    tryOrganizeSourceWithIndex(filePath, source, index, stdlibMap(), options)
  if indexed.handled:
    return indexed.edits
  var info = cloneSourceImports(index.parsed)
  result = organizeSourceImpl(filePath, source, info, options)

proc organizeSourceWithIndex*(
    filePath, source: string, index: SourceIndex, options = defaultOrganizeOptions()
): seq[ImportEdit] =
  if index == nil or index.contentHash != contentFingerprint(source) or
      index.byteLength != source.len:
    return organizeSource(filePath, source, options)
  if index.parsed.imports.len == 0 and index.symbols.len == 0 and index.includes.len == 0 and
      index.occurrences.identifiers.len == 0 and index.occurrences.isComplete:
    return
  let indexed =
    tryOrganizeSourceWithIndex(filePath, source, index, stdlibMap(), options)
  if indexed.handled:
    return indexed.edits
  organizeSourceWithImports(filePath, source, index.parsed, options)
