import std/[algorithm, hashes, os, sets, strutils, tables]

import ./compiler_api
import ./imports
import ./lexer
import ./stdlib

type
  ImportEdit* = object
    startOffset*: int
    endOffset*: int
    newText*: string

  PlannedImport = object
    candidate: SymbolCandidate
    fromImport: bool

  OrganizeOptions* = object
    useStdPrefix*: bool

proc defaultOrganizeOptions*(): OrganizeOptions =
  OrganizeOptions(useStdPrefix: true)

proc pathForSource(filePath, source: string): tuple[path: string, temporary: bool] =
  if filePath.len > 0 and fileExists(filePath):
    try:
      if readFile(filePath) == source:
        return (filePath, false)
    except CatchableError:
      discard
  var directory = splitFile(filePath).dir
  if directory.len == 0:
    directory = getCurrentDir()
  let base = splitFile(filePath).name
  let suffix = $abs(hash(source))
  let temporary = directory / ("." & base & ".onim-" & suffix & ".nim")
  try:
    writeFile(temporary, source)
    (temporary, true)
  except CatchableError:
    (filePath, false)

proc candidatePath(candidate: SymbolCandidate, useStdPrefix: bool): string =
  if useStdPrefix or not candidate.module.startsWith("std/"):
    candidate.module
  else:
    candidate.module[4 .. ^1]

proc moduleClass(module: string): int =
  let normalized = canonicalModule(module)
  if normalized.startsWith("std/") or normalized == "os" or normalized == "tables" or
      normalized == "json" or normalized == "strutils":
    return 0
  if normalized.startsWith("./") or normalized.startsWith("../") or
      normalized.startsWith("/"):
    return 2
  1

proc plannedImportOrder(left, right: PlannedImport): int =
  let leftClass = moduleClass(left.candidate.module)
  let rightClass = moduleClass(right.candidate.module)
  if leftClass != rightClass:
    return cmp(leftClass, rightClass)
  cmp(canonicalModule(left.candidate.module), canonicalModule(right.candidate.module))

proc statementEndWithNewline(source: string, item: ImportInfo): int =
  lineEndOffset(source, item.endOffset)

proc isStdModule(module: string, stdlib: StdlibMap): bool =
  let normalized = canonicalModule(module)
  normalized.startsWith("std/") or stdlib.modules.hasKey("std/" & normalized)

proc canonicalStdModule(module: string): string =
  let normalized = canonicalModule(module)
  if normalized.startsWith("std/"):
    normalized
  else:
    "std/" & normalized

proc addUniqueStdModule(modules: var seq[string], module: string) =
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

proc groupableStdImports(
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

proc stdModulesOnStatement(
    imports: SourceImports, statement: ImportInfo, stdlib: StdlibMap
): seq[string] =
  for item in imports.imports:
    if item.synthetic or item.startOffset != statement.startOffset or
        item.endOffset != statement.endOffset:
      continue
    if item.form == importModule and item.alias.len == 0 and item.excluded.len == 0 and
        isStdModule(item.module, stdlib):
      addUniqueStdModule(result, item.module)

proc addUniqueModule(
    modules: var seq[PlannedImport], candidate: SymbolCandidate, fromImport: bool
) =
  for existing in modules:
    if sameModule(existing.candidate.module, candidate.module) and
        existing.fromImport == fromImport and
        (not fromImport or existing.candidate.name == candidate.name):
      return
  modules.add PlannedImport(candidate: candidate, fromImport: fromImport)

proc findFromImport(imports: SourceImports, module: string, name: string): int =
  for index, item in imports.imports:
    if item.synthetic or item.conditional:
      continue
    if item.form == fromModule and item.alias.len == 0 and
        sameModule(item.module, module) and name notin item.imported:
      return index
  -1

proc findExistingModule(
    imports: SourceImports, module: string
): tuple[plain, aliased, excluded: int] =
  result = (-1, -1, -1)
  for index, item in imports.imports:
    if item.synthetic or item.conditional:
      continue
    if item.form != importModule or not sameModule(item.module, module):
      continue
    if item.alias.len > 0:
      result.aliased = index
    elif item.excluded.len > 0:
      result.excluded = index
    else:
      result.plain = index

proc sourceImportInsertion(
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

proc renderStdImports(
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

proc renderNewImports(
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

proc findUsageToken(info: SourceImports, diagnostic: CompilerDiagnostic): int =
  var best = -1
  var bestDistance = high(int)
  for index, token in info.tokens:
    if token.kind != tkIdentifier or token.text != diagnostic.name:
      continue
    let distance =
      abs(token.line - diagnostic.line) * 10000 + abs(token.column - diagnostic.column)
    if distance < bestDistance:
      best = index
      bestDistance = distance
  best

proc callArity(info: SourceImports, source: string, tokenIndex: int): int =
  if tokenIndex < 0 or tokenIndex + 1 >= info.tokens.len or
      info.tokens[tokenIndex + 1].text != "(":
    return -1
  var depth = 0
  var commas = 0
  for index in tokenIndex + 1 ..< info.tokens.len:
    let text = info.tokens[index].text
    if text == "(":
      inc depth
    elif text == ")":
      dec depth
      if depth == 0:
        let content =
          source[
            info.tokens[tokenIndex + 1].endOffset ..< info.tokens[index].startOffset
          ].strip
        if content.len == 0:
          return 0
        return commas + 1
    elif depth == 1 and text == ",":
      inc commas
  -1

proc qualifiedMember(
    info: SourceImports, diagnostic: CompilerDiagnostic
): tuple[qualifier, member: string] =
  let tokenIndex = findUsageToken(info, diagnostic)
  if tokenIndex >= 0 and tokenIndex + 2 < info.tokens.len and
      info.tokens[tokenIndex + 1].text == "." and
      info.tokens[tokenIndex + 2].kind == tkIdentifier:
    return (info.tokens[tokenIndex].text, info.tokens[tokenIndex + 2].text)
  ("", "")

proc importsAvailableFromIncluded(
    sourcePath: string,
    info: var SourceImports,
    visited: var HashSet[string],
    depth: int,
) =
  if depth > 8:
    return
  for tokenIndex, token in info.tokens:
    if token.text != "include" or tokenIndex + 1 >= info.tokens.len:
      continue
    let includeToken = info.tokens[tokenIndex + 1]
    var includeName = includeToken.text.strip(chars = {'"', '\'', '`'})
    if includeName.len == 0:
      continue
    if not includeName.endsWith(".nim"):
      includeName.add ".nim"
    let includePath =
      if isAbsolute(includeName):
        includeName
      else:
        splitFile(sourcePath).dir / includeName
    let absolute = absolutePath(includePath)
    if absolute in visited or not fileExists(absolute):
      continue
    visited.incl absolute
    try:
      let included = parseSourceImports(readFile(absolute))
      for name in included.localDefinitions:
        info.localDefinitions.incl name
        info.availableNames.incl name
      for name in included.availableNames:
        info.availableNames.incl name
      for name in included.qualifiedNames:
        info.qualifiedNames.incl name
      var nested = included
      importsAvailableFromIncluded(absolute, nested, visited, depth + 1)
      for name in nested.localDefinitions:
        info.localDefinitions.incl name
        info.availableNames.incl name
      for name in nested.availableNames:
        info.availableNames.incl name
      for name in nested.qualifiedNames:
        info.qualifiedNames.incl name
      for item in nested.imports:
        var importedItem = item
        importedItem.synthetic = true
        info.imports.add importedItem
    except CatchableError:
      discard

proc applyEdits*(source: string, edits: seq[ImportEdit]): string

proc validatesEdits(
    filePath, source: string,
    edits: seq[ImportEdit],
    baseline: seq[CompilerDiagnostic],
    targets: HashSet[string],
): bool =
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
  # Validate the edited bytes as their own project. A dirty path deliberately
  # has a different basename, and passing it alongside the original project
  # makes nimsuggest reuse the original module graph for some import shapes.
  let projectPath =
    if filePath.len > 0:
      absolutePath(filePath)
    else:
      absolutePath(materialized.path)
  let after = checkFileCached(projectPath, absolutePath(materialized.path))
  var beforeNames = initHashSet[string]()
  for diagnostic in baseline:
    beforeNames.incl diagnostic.name
  for diagnostic in after:
    if diagnostic.name in targets or diagnostic.name notin beforeNames:
      return false
  true

proc organizeSourceImpl(
    filePath, source: string,
    info: var SourceImports,
    options = defaultOrganizeOptions(),
): seq[ImportEdit] =
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
  if diagnostics.len == 0:
    return
  let stdlib = stdlibMap()
  var newModules: seq[PlannedImport] = @[]
  var amendedFrom = initHashSet[string]()
  var seenNames = initHashSet[string]()
  var targetNames = initHashSet[string]()

  for diagnostic in diagnostics:
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

    let existing = findExistingModule(info, candidate.module)
    if existing.plain >= 0 and qualifier.len == 0:
      continue
    if existing.plain >= 0 and qualifier.len > 0:
      continue
    if existing.aliased >= 0 or existing.excluded >= 0 or
        findFromImport(info, candidate.module, name) >= 0:
      let key = canonicalModule(candidate.module) & "|" & name
      if key notin amendedFrom:
        amendedFrom.incl key
        let fromIndex = findFromImport(info, candidate.module, name)
        if fromIndex >= 0:
          let item = info.imports[fromIndex]
          result.add ImportEdit(
            startOffset: item.endOffset, endOffset: item.endOffset, newText: ", " & name
          )
        else:
          addUniqueModule(newModules, candidate, true)
      continue
    addUniqueModule(newModules, candidate, false)

  if newModules.len > 0:
    let newline = if source.contains("\r\n"): "\r\n" else: "\n"
    var stdCandidates: seq[PlannedImport] = @[]
    var otherCandidates: seq[PlannedImport] = @[]
    for planned in newModules:
      if not planned.fromImport and
          canonicalModule(planned.candidate.module).startsWith("std/"):
        stdCandidates.add planned
      else:
        otherCandidates.add planned

    let existingStd = groupableStdImports(source, info, stdlib)
    if stdCandidates.len > 0 and existingStd.len > 0:
      var existingStdModules: seq[string] = @[]
      for statement in existingStd:
        for module in stdModulesOnStatement(info, statement, stdlib):
          addUniqueStdModule(existingStdModules, module)

      let insertion =
        sourceImportInsertion(source, info, stdCandidates[0].candidate, stdlib, true)
      let replacementEnd = statementEndWithNewline(source, existingStd[0])
      var mergeOtherCandidates = false
      if otherCandidates.len > 0:
        var orderedOther = otherCandidates
        orderedOther.sort(plannedImportOrder)
        let otherInsertion =
          sourceImportInsertion(source, info, orderedOther[0].candidate, stdlib)
        for item in existingStd:
          let lineStart = item.startOffset - item.indent.len
          let lineEnd = statementEndWithNewline(source, item)
          if otherInsertion >= lineStart and otherInsertion < lineEnd:
            mergeOtherCandidates = true
            break

      var replacementCandidates = stdCandidates
      if mergeOtherCandidates:
        replacementCandidates = newModules
        otherCandidates.setLen(0)
      result.add ImportEdit(
        startOffset: insertion,
        endOffset: replacementEnd,
        newText: renderNewImports(
          replacementCandidates, options.useStdPrefix, newline, existingStdModules
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
          sourceImportInsertion(source, info, orderedOther[0].candidate, stdlib)
        result.add ImportEdit(
          startOffset: otherInsertion,
          endOffset: otherInsertion,
          newText: renderNewImports(otherCandidates, options.useStdPrefix, newline),
        )
    else:
      var orderedModules = newModules
      orderedModules.sort(plannedImportOrder)
      let insertion =
        sourceImportInsertion(source, info, orderedModules[0].candidate, stdlib)
      var newText = renderNewImports(newModules, options.useStdPrefix, newline)
      var physicalImportCount = 0
      for item in info.imports:
        if not item.synthetic:
          inc physicalImportCount
      if physicalImportCount == 0:
        newText.add newline
      result.add ImportEdit(
        startOffset: insertion, endOffset: insertion, newText: newText
      )

  if result.len > 0 and
      not validatesEdits(filePath, source, result, diagnostics, targetNames):
    result.setLen(0)

proc organizeSourceWithImports*(
    filePath, source: string, parsed: SourceImports, options = defaultOrganizeOptions()
): seq[ImportEdit] =
  var info = cloneSourceImports(parsed)
  result = organizeSourceImpl(filePath, source, info, options)

proc organizeSource*(
    filePath, source: string, options = defaultOrganizeOptions()
): seq[ImportEdit] =
  var info = parseSourceImports(source)
  result = organizeSourceImpl(filePath, source, info, options)

proc applyEdits*(source: string, edits: seq[ImportEdit]): string =
  var ordered = edits
  ordered.sort(
    proc(left, right: ImportEdit): int =
      cmp(right.startOffset, left.startOffset)
  )
  result = source
  for edit in ordered:
    if edit.startOffset < 0 or edit.endOffset < edit.startOffset or
        edit.endOffset > result.len:
      continue
    let suffix =
      if edit.endOffset < result.len:
        result[edit.endOffset .. ^1]
      else:
        ""
    result = result[0 ..< edit.startOffset] & edit.newText & suffix

proc organizeFile*(filePath: string, options = defaultOrganizeOptions()): bool =
  if filePath.toLowerAscii.endsWith(".nimble") or filePath.toLowerAscii.endsWith(".cfg"):
    return false
  if not fileExists(filePath):
    return false
  let source = readFile(filePath)
  let edits = organizeSource(filePath, source, options)
  if edits.len == 0:
    return false
  let organized = applyEdits(source, edits)
  if organized == source:
    return false
  writeFile(filePath, organized)
  true
