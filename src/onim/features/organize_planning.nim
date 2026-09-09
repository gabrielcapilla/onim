import std/[algorithm, sets, strutils]

import ../stdlib/map
import ../syntax/imports
import ../syntax/source_lines
import ../syntax/tokens
import ./organize_edits

type PlannedImport* = object
  candidate*: SymbolCandidate
  fromImport*: bool

proc candidatePath(candidate: SymbolCandidate, useStdPrefix: bool): string =
  if useStdPrefix or not candidate.module.startsWith("std/"):
    candidate.module
  else:
    candidate.module[4 .. ^1]

proc moduleClass(module: string): uint8 =
  let normalized = canonicalModule(module)
  if normalized.startsWith("std/"):
    return 0'u8
  if normalized.startsWith("./") or normalized.startsWith("../") or
      normalized.startsWith("/"):
    return 2'u8
  1'u8

proc plannedImportOrder*(left, right: PlannedImport): int =
  let leftClass = moduleClass(left.candidate.module)
  let rightClass = moduleClass(right.candidate.module)
  if leftClass != rightClass:
    return cmp(leftClass, rightClass)
  cmp(canonicalModule(left.candidate.module), canonicalModule(right.candidate.module))

proc statementEndWithNewline*(source: string, item: ImportInfo): int =
  lineEndOffset(source, item.endOffset)

proc isStdModule*(module: string, stdlib: StdlibMap): bool =
  let normalized = canonicalModule(module)
  normalized.startsWith("std/") or ("std/" & normalized) in stdlib.modules

proc canonicalStdModule(module: string): string =
  let normalized = canonicalModule(module)
  if normalized.startsWith("std/"):
    normalized
  else:
    "std/" & normalized

proc addUniqueStdModule*(modules: var seq[string], module: string) =
  let normalized = canonicalStdModule(module)
  for existing in modules:
    if existing == normalized:
      return
  modules.add normalized

proc canGroupStdImport(
    source: string, imports: SourceImports, item: ImportInfo, stdlib: StdlibMap
): bool =
  if item.synthetic or item.conditional or item.form != importModule or
      item.alias.len > 0 or item.excluded.len > 0 or not isStdModule(
    item.module, stdlib
  ):
    return false
  let lineEnd = statementEndWithNewline(source, item)
  if item.endOffset < lineEnd and source[item.endOffset ..< lineEnd].strip.len > 0:
    return false
  for peer in imports.imports:
    if peer.synthetic or peer.startOffset != item.startOffset or
        peer.endOffset != item.endOffset:
      continue
    if peer.conditional or peer.form != importModule or peer.alias.len > 0 or
        peer.excluded.len > 0 or not isStdModule(peer.module, stdlib):
      return false
  true

proc groupableStdImports*(
    source: string, imports: SourceImports, stdlib: StdlibMap
): seq[ImportInfo] =
  var seenStarts = initHashSet[int]()
  for item in imports.imports:
    if item.startOffset in seenStarts:
      continue
    if canGroupStdImport(source, imports, item, stdlib):
      seenStarts.incl item.startOffset
      result.add item
  result.sort(
    proc(left, right: ImportInfo): int =
      cmp(left.startOffset, right.startOffset)
  )

proc stdModulesOnStatement*(
    imports: SourceImports, statement: ImportInfo, stdlib: StdlibMap
): seq[string] =
  for item in imports.imports:
    if item.synthetic or item.startOffset != statement.startOffset or
        item.endOffset != statement.endOffset:
      continue
    if item.form == importModule and item.alias.len == 0 and item.excluded.len == 0 and
        isStdModule(item.module, stdlib):
      addUniqueStdModule(result, item.module)

proc addUniqueModule*(
    modules: var seq[PlannedImport], candidate: SymbolCandidate, fromImport: bool
) =
  for existing in modules:
    if sameModule(existing.candidate.module, candidate.module) and
        existing.fromImport == fromImport and
        (not fromImport or existing.candidate.name == candidate.name):
      return
  modules.add PlannedImport(candidate: candidate, fromImport: fromImport)

proc sourceImportInsertion*(
    source: string,
    imports: SourceImports,
    candidate: SymbolCandidate,
    stdlib: StdlibMap,
    groupStdModules = false,
): int =
  if groupStdModules:
    let existingStd = groupableStdImports(source, imports, stdlib)
    if existingStd.len > 0:
      return existingStd[0].startOffset

  var physical: seq[ImportInfo] = @[]
  for item in imports.imports:
    if not item.synthetic:
      physical.add item
  if physical.len == 0:
    if imports.tokens.len > 0:
      return imports.tokens[0].startOffset
    return source.len

  let wantedClass = moduleClass(candidate.module)
  let wantedModule = canonicalModule(candidate.module)
  for item in physical:
    let currentClass = moduleClass(item.module)
    let currentModule = canonicalModule(item.module)
    if wantedClass < currentClass or
        (wantedClass == currentClass and wantedModule < currentModule):
      return item.startOffset
  statementEndWithNewline(source, physical[^1])

proc insertionSplitsConditionalImport(
    source: string,
    imports: SourceImports,
    candidate: SymbolCandidate,
    stdlib: StdlibMap,
): bool =
  let insertion = sourceImportInsertion(source, imports, candidate, stdlib)
  for item in imports.imports:
    if not item.synthetic and item.conditional and item.indent.len > 0:
      let lineStart = item.startOffset - item.indent.len
      if insertion >= lineStart and insertion <= item.startOffset:
        return true

proc unsafeImportInsertion*(
    source: string,
    imports: SourceImports,
    candidates: openArray[PlannedImport],
    stdlib: StdlibMap,
): bool =
  if candidates.len == 0:
    return false
  var stdCandidates: seq[PlannedImport] = @[]
  var otherCandidates: seq[PlannedImport] = @[]
  for candidate in candidates:
    if not candidate.fromImport and
        canonicalModule(candidate.candidate.module).startsWith("std/"):
      stdCandidates.add candidate
    else:
      otherCandidates.add candidate
  let existingStd = groupableStdImports(source, imports, stdlib)
  if stdCandidates.len > 0 and existingStd.len > 0:
    if insertionSplitsConditionalImport(
      source, imports, stdCandidates[0].candidate, stdlib
    ):
      return true
    if otherCandidates.len == 0:
      return false
    otherCandidates.sort(plannedImportOrder)
    return insertionSplitsConditionalImport(
      source, imports, otherCandidates[0].candidate, stdlib
    )
  var ordered: seq[PlannedImport] = @[]
  for candidate in candidates:
    ordered.add candidate
  ordered.sort(plannedImportOrder)
  insertionSplitsConditionalImport(source, imports, ordered[0].candidate, stdlib)

proc renderStdImports*(
    modules: seq[string], useStdPrefix: bool, newline: string
): string =
  var ordered: seq[string] = @[]
  for module in modules:
    addUniqueStdModule(ordered, module)
  ordered.sort

  if useStdPrefix and ordered.len >= 2:
    var names: seq[string] = @[]
    for module in ordered:
      names.add module[4 .. ^1]
    return "import std/[" & names.join(", ") & "]" & newline

  for module in ordered:
    let path =
      if useStdPrefix:
        module
      else:
        module[4 .. ^1]
    result.add "import " & path & newline

proc renderNewImports*(
    candidates: seq[PlannedImport],
    useStdPrefix: bool,
    newline: string,
    existingStdModules: seq[string] = @[],
): string =
  var ordered = candidates
  ordered.sort(plannedImportOrder)

  var stdModules: seq[string] = @[]
  for module in existingStdModules:
    addUniqueStdModule(stdModules, module)
  for planned in ordered:
    if not planned.fromImport and
        canonicalModule(planned.candidate.module).startsWith("std/"):
      addUniqueStdModule(stdModules, planned.candidate.module)
  if stdModules.len > 0:
    result.add renderStdImports(stdModules, useStdPrefix, newline)

  for planned in ordered:
    let candidate = planned.candidate
    if planned.fromImport:
      result.add "from " & candidatePath(candidate, useStdPrefix) & " import " &
        candidate.name & newline
    elif not canonicalModule(candidate.module).startsWith("std/"):
      result.add "import " & candidatePath(candidate, useStdPrefix) & newline

proc renderImportAdditions*(
    source: string,
    imports: SourceImports,
    candidates: seq[PlannedImport],
    stdlib: StdlibMap,
    useStdPrefix: bool,
    newline: string,
): seq[ImportEdit] =
  var stdCandidates: seq[PlannedImport] = @[]
  var otherCandidates: seq[PlannedImport] = @[]
  for planned in candidates:
    if not planned.fromImport and
        canonicalModule(planned.candidate.module).startsWith("std/"):
      stdCandidates.add planned
    else:
      otherCandidates.add planned

  let existingStd = groupableStdImports(source, imports, stdlib)
  if stdCandidates.len > 0 and existingStd.len > 0:
    var existingStdModules: seq[string] = @[]
    for statement in existingStd:
      for module in stdModulesOnStatement(imports, statement, stdlib):
        addUniqueStdModule(existingStdModules, module)

    let insertion =
      sourceImportInsertion(source, imports, stdCandidates[0].candidate, stdlib, true)
    let replacementEnd = statementEndWithNewline(source, existingStd[0])
    var mergeOtherCandidates = false
    if otherCandidates.len > 0:
      var orderedOther = otherCandidates
      orderedOther.sort(plannedImportOrder)
      let otherInsertion =
        sourceImportInsertion(source, imports, orderedOther[0].candidate, stdlib)
      for item in existingStd:
        let lineStart = item.startOffset - item.indent.len
        let lineEnd = statementEndWithNewline(source, item)
        if otherInsertion >= lineStart and otherInsertion < lineEnd:
          mergeOtherCandidates = true
          break

    var replacementCandidates = stdCandidates
    if mergeOtherCandidates:
      replacementCandidates = candidates
      otherCandidates.setLen(0)
    result.add ImportEdit(
      startOffset: insertion,
      endOffset: replacementEnd,
      newText: renderNewImports(
        replacementCandidates, useStdPrefix, newline, existingStdModules
      ),
    )
    if existingStd.len > 1:
      for index in 1 ..< existingStd.len:
        let item = existingStd[index]
        result.add ImportEdit(
          startOffset: item.startOffset - item.indent.len,
          endOffset: statementEndWithNewline(source, item),
          newText: "",
        )

    if otherCandidates.len > 0:
      var orderedOther = otherCandidates
      orderedOther.sort(plannedImportOrder)
      let otherInsertion =
        sourceImportInsertion(source, imports, orderedOther[0].candidate, stdlib)
      result.add ImportEdit(
        startOffset: otherInsertion,
        endOffset: otherInsertion,
        newText: renderNewImports(otherCandidates, useStdPrefix, newline),
      )
  elif candidates.len > 0:
    var orderedModules = candidates
    orderedModules.sort(plannedImportOrder)
    let insertion =
      sourceImportInsertion(source, imports, orderedModules[0].candidate, stdlib)
    var newText = renderNewImports(candidates, useStdPrefix, newline)
    var physicalImportCount = 0
    for item in imports.imports:
      if not item.synthetic:
        inc physicalImportCount
    if physicalImportCount == 0:
      newText.add newline
    result.add ImportEdit(
      startOffset: insertion, endOffset: insertion, newText: newText
    )
