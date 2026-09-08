import std/[algorithm, hashes, os, sets, strutils, tables]

import ../index/bindings
import ../index/occurrences
import ../index/scopes
import ../index/cache
import ../index/source_index
import ../index/symbols
import ../index/surfaces
import ../semantic/compiler_api
import ../session/module_catalog
import ../stdlib/map
import ../syntax/imports
import ../syntax/lexer

type
  ImportEdit* = object
    startOffset*: int
    endOffset*: int
    newText*: string

  PlannedImport = object
    candidate: SymbolCandidate
    fromImport: bool

  ImportRemovalPlan = object
    whole: HashSet[int]
    symbols: seq[HashSet[string]]

  OrganizeOptions* = object
    useStdPrefix*: bool

  NativeBindingState = enum
    nativeNoBinding
    nativeBound
    nativeUnknown

  NativeModuleUse = enum
    nativeModuleUseNone
    nativeModuleUseFound
    nativeModuleUseUnknown

  NativeRemovalState = enum
    nativeRemovalUnsupported
    nativeRemovalReady

  NativeCandidateState = enum
    nativeCandidateNone
    nativeCandidateResolved
    nativeCandidateAmbiguous
    nativeCandidateUnknown

  NativeCandidateSource = enum
    nativeCandidateStdlibSource
    nativeCandidateProjectSource

  IncludedImportCacheEntry = object
    stamp: FileStamp
    imports: SourceImports

const maxIncludedImportCacheEntries = 128

var includedImportCache = initTable[string, IncludedImportCacheEntry]()

proc defaultOrganizeOptions*(): OrganizeOptions =
  OrganizeOptions(useStdPrefix: true)

proc initImportRemovalPlan(imports: SourceImports): ImportRemovalPlan =
  result.whole = initHashSet[int]()
  result.symbols = newSeq[HashSet[string]](imports.imports.len)
  for index in 0 ..< result.symbols.len:
    result.symbols[index] = initHashSet[string]()

proc hasImportRemovals(plan: ImportRemovalPlan): bool =
  if plan.whole.len > 0:
    return true
  for names in plan.symbols:
    if names.len > 0:
      return true

proc promoteEmptyFromImports(imports: SourceImports, plan: var ImportRemovalPlan) =
  for index, item in imports.imports:
    if item.form != fromModule or plan.symbols[index].len == 0:
      continue
    var allSymbolsRemoved = item.importedSymbols.len > 0
    for symbol in item.importedSymbols:
      if symbol.name notin plan.symbols[index]:
        allSymbolsRemoved = false
        break
    if allSymbolsRemoved:
      plan.symbols[index].clear
      plan.whole.incl index

proc diagnosticBelongsToSource(
    diagnostic: CompilerDiagnostic, filePath, materializedPath: string
): bool =
  if diagnostic.file.len == 0:
    return true
  let reported = diagnostic.file.strip(chars = {'"', '\'', '`'})
  if reported.len == 0:
    return true
  let reportedPath = absolutePath(reported)
  if reportedPath == absolutePath(filePath) or
      reportedPath == absolutePath(materializedPath):
    return true
  if not reported.contains('/') and not reported.contains('\\'):
    return splitFile(reportedPath).name == splitFile(absolutePath(filePath)).name
  false

proc diagnosticMatchesImport(item: ImportInfo, diagnostic: CompilerDiagnostic): bool =
  let normalized = canonicalModule(item.module)
  let leaf = moduleLeaf(item.module)
  if diagnostic.name == item.alias or diagnostic.name == item.module or
      diagnostic.name == normalized or diagnostic.name == leaf:
    return true
  item.form == fromModule and diagnostic.name in item.imported

proc hasMissingExcludedSymbol(
    item: ImportInfo,
    diagnostics: seq[CompilerDiagnostic],
    filePath, materializedPath: string,
): bool =
  if item.excluded.len == 0:
    return false
  for diagnostic in diagnostics:
    if not diagnostic.isUnusedImport and diagnostic.name in item.excluded and
        diagnosticBelongsToSource(diagnostic, filePath, materializedPath):
      return true

proc diagnosticRange(
    item: ImportInfo, diagnostic: CompilerDiagnostic
): tuple[startOffset, endOffset: int] =
  result = (item.diagnosticNameStartOffset, item.diagnosticNameEndOffset)
  if item.form == fromModule and diagnostic.name in item.imported:
    for symbol in item.importedSymbols:
      if symbol.name == diagnostic.name:
        return (symbol.startOffset, symbol.endOffset)

proc findUnusedImport(
    source, filePath, materializedPath: string,
    imports: SourceImports,
    diagnostic: CompilerDiagnostic,
): int =
  var bestScore = -1
  var bestIndex = -1
  var ambiguous = false
  for index, item in imports.imports:
    if item.synthetic or item.conditional or item.keep or
        not diagnosticBelongsToSource(diagnostic, filePath, materializedPath) or
        not diagnosticMatchesImport(item, diagnostic):
      continue
    var score = 1
    if item.line == diagnostic.line:
      score += 100
      let location = lineStartOffset(source, diagnostic.line) + diagnostic.column
      let range = diagnosticRange(item, diagnostic)
      if diagnostic.column >= 0 and location >= range.startOffset and
          location < range.endOffset:
        score += 100
    if score > bestScore:
      bestScore = score
      bestIndex = index
      ambiguous = false
    elif score == bestScore:
      ambiguous = true
  if ambiguous: -1 else: bestIndex

proc hasIncludedSource(imports: SourceImports): bool =
  for token in imports.tokens:
    if token.isKeyword(kwInclude):
      return true

proc importedNameUsed(
    source: string, imports: SourceImports, item: ImportInfo, name: string
): bool =
  for tokenIndex, token in imports.tokens:
    if token.kind != tkIdentifier or not imports.tokens.tokenTextEquals(token, name) or
        token.startOffset <= item.endOffset or imports.tokenInsideImport(token):
      continue
    if tokenIndex > 0 and
        imports.tokens.tokenTextEquals(imports.tokens[tokenIndex - 1], "."):
      continue
    if name in imports.localDefinitions:
      return true
    return true

proc collectUnusedImportPlan(
    source, filePath, materializedPath: string,
    imports: SourceImports,
    diagnostics: seq[CompilerDiagnostic],
): tuple[plan: ImportRemovalPlan, targets: HashSet[string]] =
  result.plan = initImportRemovalPlan(imports)
  result.targets = initHashSet[string]()
  for diagnostic in diagnostics:
    if not diagnostic.isUnusedImport:
      continue
    let index =
      findUnusedImport(source, filePath, materializedPath, imports, diagnostic)
    if index < 0:
      continue
    let item = imports.imports[index]
    if hasMissingExcludedSymbol(item, diagnostics, filePath, materializedPath):
      continue
    result.targets.incl diagnostic.name
    if item.form == fromModule and diagnostic.name in item.imported and
        diagnostic.name != moduleLeaf(item.module):
      result.plan.symbols[index].incl diagnostic.name
    else:
      result.plan.whole.incl index

  if hasIncludedSource(imports):
    return
  for index, item in imports.imports:
    if item.synthetic or item.conditional or item.keep or item.form != fromModule or
        result.plan.whole.contains(index):
      continue
    for symbol in item.importedSymbols:
      if symbol.name notin result.plan.symbols[index] and
          not importedNameUsed(source, imports, item, symbol.name):
        result.plan.symbols[index].incl symbol.name

  promoteEmptyFromImports(imports, result.plan)

proc activeImportInfo(imports: SourceImports, plan: ImportRemovalPlan): SourceImports =
  result = cloneSourceImports(imports)
  result.imports.setLen(0)
  for index, item in imports.imports:
    if plan.whole.contains(index):
      continue
    var active = item
    if index < plan.symbols.len and plan.symbols[index].len > 0:
      active.imported = initHashSet[string]()
      active.importedSymbols = @[]
      for name in item.imported:
        if name notin plan.symbols[index]:
          active.imported.incl name
      for symbol in item.importedSymbols:
        if symbol.name notin plan.symbols[index]:
          active.importedSymbols.add symbol
    result.imports.add active

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
  let identity =
    if filePath.len > 0:
      absolutePath(filePath)
    else:
      base
  let suffix = $abs(hash(identity))
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

proc moduleClass(module: string): uint8 =
  let normalized = canonicalModule(module)
  if normalized.startsWith("std/"):
    return 0'u8
  if normalized.startsWith("./") or normalized.startsWith("../") or
      normalized.startsWith("/"):
    return 2'u8
  1'u8

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
  normalized.startsWith("std/") or ("std/" & normalized) in stdlib.modules

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
    if token.kind != tkIdentifier or
        not info.tokens.tokenTextEquals(token, diagnostic.name):
      continue
    let distance =
      abs(token.line - diagnostic.line) * 10000 + abs(token.column - diagnostic.column)
    if distance < bestDistance:
      best = index
      bestDistance = distance
  best

proc callArity(info: SourceImports, source: string, tokenIndex: int): int =
  if tokenIndex < 0 or tokenIndex + 1 >= info.tokens.len or
      not info.tokens.tokenTextEquals(info.tokens[tokenIndex + 1], "("):
    return -1
  var depth = 0
  var commas = 0
  for index in tokenIndex + 1 ..< info.tokens.len:
    if info.tokens.tokenTextEquals(info.tokens[index], "("):
      inc depth
    elif info.tokens.tokenTextEquals(info.tokens[index], ")"):
      dec depth
      if depth == 0:
        let content =
          source[
            info.tokens[tokenIndex + 1].endOffset ..< info.tokens[index].startOffset
          ].strip
        if content.len == 0:
          return 0
        return commas + 1
    elif depth == 1 and info.tokens.tokenTextEquals(info.tokens[index], ","):
      inc commas
  -1

proc qualifiedMember(
    info: SourceImports, diagnostic: CompilerDiagnostic
): tuple[qualifier, member: string] =
  let tokenIndex = findUsageToken(info, diagnostic)
  if tokenIndex >= 0 and tokenIndex + 2 < info.tokens.len and
      info.tokens.tokenTextEquals(info.tokens[tokenIndex + 1], ".") and
      info.tokens[tokenIndex + 2].kind == tkIdentifier:
    return (
      info.tokens.tokenText(info.tokens[tokenIndex]),
      info.tokens.tokenText(info.tokens[tokenIndex + 2]),
    )
  ("", "")

proc mergeIncludedNames(target: var SourceImports, source: SourceImports) =
  for name in source.localDefinitions:
    target.localDefinitions.incl name
    target.availableNames.incl name
  for name in source.availableNames:
    target.availableNames.incl name
  for name in source.qualifiedNames:
    target.qualifiedNames.incl name

proc cachedIncludedImports(path: string, imports: var SourceImports): bool =
  let stamp = fileStamp(path)
  if not usableStamp(stamp):
    return false
  if includedImportCache.hasKey(path) and
      sameFileStamp(includedImportCache[path].stamp, stamp):
    imports = cloneSourceImports(includedImportCache[path].imports)
    return true
  try:
    let parsed = parseSourceImports(readFile(path))
    if includedImportCache.len >= maxIncludedImportCacheEntries:
      includedImportCache.clear()
    includedImportCache[path] = IncludedImportCacheEntry(stamp: stamp, imports: parsed)
    imports = cloneSourceImports(parsed)
    true
  except CatchableError:
    false

proc importsAvailableFromIncluded(
    sourcePath: string,
    info: var SourceImports,
    visited: var HashSet[string],
    depth: int,
) =
  if depth > 8:
    return
  for tokenIndex, token in info.tokens:
    if not token.isKeyword(kwInclude) or tokenIndex + 1 >= info.tokens.len:
      continue
    let includeToken = info.tokens[tokenIndex + 1]
    var includeName =
      info.tokens.tokenText(includeToken).strip(chars = {'"', '\'', '`'})
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
    if absolute in visited:
      continue
    visited.incl absolute
    var included: SourceImports
    if not cachedIncludedImports(absolute, included):
      continue
    mergeIncludedNames(info, included)
    var nested = cloneSourceImports(included)
    importsAvailableFromIncluded(absolute, nested, visited, depth + 1)
    mergeIncludedNames(info, nested)
    for item in nested.imports:
      var importedItem = item
      importedItem.synthetic = true
      info.imports.add importedItem

proc applyEdits*(source: string, edits: seq[ImportEdit]): string

proc noImportEdit(): ImportEdit =
  ImportEdit(startOffset: -1, endOffset: -1, newText: "")

proc appendWholeRemovalRuns(
    imports: SourceImports,
    items: seq[int],
    plan: ImportRemovalPlan,
    statementStart: int,
    edits: var seq[ImportEdit],
) =
  var cursor = 0
  while cursor < items.len:
    if not plan.whole.contains(items[cursor]):
      inc cursor
      continue
    let runStart = cursor
    while cursor < items.len and plan.whole.contains(items[cursor]):
      inc cursor
    let runEnd = cursor - 1
    let firstRemoved = imports.imports[items[runStart]]
    let lastRemoved = imports.imports[items[runEnd]]
    if runStart == 0:
      if runEnd + 1 < items.len:
        let nextSurvivor = imports.imports[items[runEnd + 1]]
        edits.add ImportEdit(
          startOffset: firstRemoved.itemStartOffset - statementStart,
          endOffset: nextSurvivor.itemStartOffset - statementStart,
          newText: "",
        )
    elif runEnd + 1 < items.len:
      let previousSurvivor = imports.imports[items[runStart - 1]]
      let nextSurvivor = imports.imports[items[runEnd + 1]]
      edits.add ImportEdit(
        startOffset: previousSurvivor.itemEndOffset - statementStart,
        endOffset: nextSurvivor.itemStartOffset - statementStart,
        newText: ", ",
      )
    else:
      let previousSurvivor = imports.imports[items[runStart - 1]]
      let removalStart =
        if firstRemoved.separatorStartOffset >= 0:
          firstRemoved.separatorStartOffset
        else:
          previousSurvivor.itemEndOffset
      edits.add ImportEdit(
        startOffset: removalStart - statementStart,
        endOffset: lastRemoved.itemEndOffset - statementStart,
        newText: "",
      )

proc appendSymbolRemovalRuns(
    symbols: seq[ImportSymbol],
    removed: HashSet[string],
    statementStart: int,
    edits: var seq[ImportEdit],
) =
  var cursor = 0
  while cursor < symbols.len:
    if symbols[cursor].name notin removed:
      inc cursor
      continue
    let runStart = cursor
    while cursor < symbols.len and symbols[cursor].name in removed:
      inc cursor
    let runEnd = cursor - 1
    let firstRemoved = symbols[runStart]
    let lastRemoved = symbols[runEnd]
    if runStart == 0:
      if runEnd + 1 < symbols.len:
        edits.add ImportEdit(
          startOffset: firstRemoved.startOffset - statementStart,
          endOffset: symbols[runEnd + 1].startOffset - statementStart,
          newText: "",
        )
    elif runEnd + 1 < symbols.len:
      edits.add ImportEdit(
        startOffset: symbols[runStart - 1].endOffset - statementStart,
        endOffset: symbols[runEnd + 1].startOffset - statementStart,
        newText: ", ",
      )
    else:
      edits.add ImportEdit(
        startOffset: symbols[runStart - 1].endOffset - statementStart,
        endOffset: lastRemoved.endOffset - statementStart,
        newText: "",
      )

proc stripFinalNewline(value, newline: string): string =
  result = value
  if result.endsWith(newline):
    result.setLen(result.len - newline.len)

proc indentImportText(value, indent, newline: string): string =
  let hasFinalNewline = value.endsWith(newline)
  var body = stripFinalNewline(value, newline)
  body = body.replace(newline, newline & indent)
  result = body
  if hasFinalNewline:
    result.add newline

proc wholeImportRemoval(source: string, item: ImportInfo): ImportEdit =
  let lineStart = item.startOffset - item.indent.len
  let lineEnd = lineEndOffset(source, item.endOffset)
  var contentEnd = lineEnd
  if contentEnd > 0 and source[contentEnd - 1] == '\n':
    dec contentEnd
  if contentEnd > 0 and source[contentEnd - 1] == '\r':
    dec contentEnd
  if source[item.endOffset ..< contentEnd].strip.len == 0:
    ImportEdit(startOffset: lineStart, endOffset: lineEnd, newText: "")
  else:
    ImportEdit(startOffset: item.startOffset, endOffset: item.endOffset, newText: "")

proc stdRemovalStatement(
    source: string,
    imports: SourceImports,
    items: seq[int],
    plan: ImportRemovalPlan,
    stdlib: StdlibMap,
    useStdPrefix: bool,
    newline: string,
): ImportEdit =
  var changed = false
  for index in items:
    if plan.whole.contains(index) or plan.symbols[index].len > 0:
      changed = true
      break
  if not changed:
    return noImportEdit()
  for index in items:
    let item = imports.imports[index]
    if item.form != importModule or item.conditional or item.alias.len > 0 or
        item.excluded.len > 0 or item.keep or not isStdModule(item.module, stdlib):
      return noImportEdit()
  var modules: seq[string] = @[]
  for index in items:
    if not plan.whole.contains(index):
      addUniqueStdModule(modules, imports.imports[index].module)
  if modules.len == 0:
    return wholeImportRemoval(source, imports.imports[items[0]])
  let first = imports.imports[items[0]]
  let rendered = indentImportText(
    renderStdImports(modules, useStdPrefix, newline), first.indent, newline
  )
  let lineEnd = lineEndOffset(source, first.endOffset)
  var contentEnd = lineEnd
  if contentEnd > 0 and source[contentEnd - 1] == '\n':
    dec contentEnd
  if contentEnd > 0 and source[contentEnd - 1] == '\r':
    dec contentEnd
  if source[first.endOffset ..< contentEnd].strip.len == 0:
    ImportEdit(startOffset: first.startOffset, endOffset: lineEnd, newText: rendered)
  else:
    ImportEdit(
      startOffset: first.startOffset,
      endOffset: first.endOffset,
      newText: stripFinalNewline(rendered, newline),
    )

proc removalStatement(
    source: string,
    imports: SourceImports,
    items: seq[int],
    plan: ImportRemovalPlan,
    stdlib: StdlibMap,
    useStdPrefix: bool,
    newline: string,
): ImportEdit =
  let first = imports.imports[items[0]]
  let stdEdit =
    stdRemovalStatement(source, imports, items, plan, stdlib, useStdPrefix, newline)
  if stdEdit.startOffset >= 0:
    return stdEdit

  var hasSurvivor = false
  for index in items:
    if not plan.whole.contains(index):
      if first.form != fromModule or plan.symbols[index].len < first.imported.len:
        hasSurvivor = true
        break
  if not hasSurvivor:
    return wholeImportRemoval(source, first)

  let statementStart = first.startOffset
  let statementEnd = first.endOffset
  var localEdits: seq[ImportEdit] = @[]
  if first.form == fromModule:
    appendSymbolRemovalRuns(
      first.importedSymbols, plan.symbols[items[0]], statementStart, localEdits
    )
  else:
    appendWholeRemovalRuns(imports, items, plan, statementStart, localEdits)
  if localEdits.len == 0:
    return noImportEdit()
  let original = source[statementStart ..< statementEnd]
  let updated = applyEdits(original, localEdits)
  if updated == original:
    return noImportEdit()
  ImportEdit(startOffset: statementStart, endOffset: statementEnd, newText: updated)

proc unusedImportEdits(
    source: string,
    imports: SourceImports,
    plan: ImportRemovalPlan,
    stdlib: StdlibMap,
    useStdPrefix: bool,
    newline: string,
): seq[ImportEdit] =
  var seenStatements = initHashSet[int]()
  for index, item in imports.imports:
    if item.synthetic or item.startOffset in seenStatements:
      continue
    seenStatements.incl item.startOffset
    var statementItems: seq[int] = @[]
    for peerIndex, peer in imports.imports:
      if not peer.synthetic and peer.startOffset == item.startOffset and
          peer.endOffset == item.endOffset:
        statementItems.add peerIndex
    let edit = removalStatement(
      source, imports, statementItems, plan, stdlib, useStdPrefix, newline
    )
    if edit.startOffset >= 0:
      result.add edit

  let active = activeImportInfo(imports, plan)
  var hasPhysicalSurvivor = false
  for item in active.imports:
    if not item.synthetic:
      hasPhysicalSurvivor = true
      break
  if not hasPhysicalSurvivor and result.len > 0:
    var firstPhysicalStart = source.len
    for item in imports.imports:
      if not item.synthetic:
        firstPhysicalStart = min(firstPhysicalStart, item.startOffset - item.indent.len)
    let hasHeader =
      firstPhysicalStart > 0 and source[0 ..< firstPhysicalStart].strip.len > 0
    var lastEdit = -1
    var lastEnd = -1
    for index, edit in result:
      if edit.newText.len == 0 and edit.endOffset > lastEnd:
        lastEdit = index
        lastEnd = edit.endOffset
    if not hasHeader and lastEdit >= 0 and result[lastEdit].endOffset < source.len:
      let blankEnd = lineEndOffset(source, result[lastEdit].endOffset)
      var blankContentEnd = blankEnd
      if blankContentEnd > result[lastEdit].endOffset and
          source[blankContentEnd - 1] == '\n':
        dec blankContentEnd
      if blankContentEnd > result[lastEdit].endOffset and
          source[blankContentEnd - 1] == '\r':
        dec blankContentEnd
      if source[result[lastEdit].endOffset ..< blankContentEnd].strip.len == 0:
        result[lastEdit].endOffset = blankEnd

proc groupedStdRemovalEdits(
    source: string,
    imports: SourceImports,
    plan: ImportRemovalPlan,
    stdlib: StdlibMap,
    useStdPrefix: bool,
    newline: string,
): seq[ImportEdit] =
  if not hasImportRemovals(plan):
    return
  let active = activeImportInfo(imports, plan)
  let statements = groupableStdImports(source, active, stdlib)
  if statements.len < 2:
    return
  var modules: seq[string] = @[]
  for statement in statements:
    for module in stdModulesOnStatement(active, statement, stdlib):
      addUniqueStdModule(modules, module)
  modules.sort
  let first = statements[0]
  result.add ImportEdit(
    startOffset: first.startOffset,
    endOffset: statementEndWithNewline(source, first),
    newText: indentImportText(
      renderStdImports(modules, useStdPrefix, newline), first.indent, newline
    ),
  )
  for index in 1 ..< statements.len:
    let item = statements[index]
    result.add ImportEdit(
      startOffset: item.startOffset - item.indent.len,
      endOffset: statementEndWithNewline(source, item),
      newText: "",
    )

proc editsDisjoint(edits: seq[ImportEdit]): bool =
  for leftIndex in 0 ..< edits.len:
    for rightIndex in leftIndex + 1 ..< edits.len:
      let left = edits[leftIndex]
      let right = edits[rightIndex]
      if left.startOffset == left.endOffset and right.startOffset == right.endOffset:
        if left.startOffset == right.startOffset:
          return false
      elif left.startOffset == left.endOffset:
        if left.startOffset > right.startOffset and left.startOffset < right.endOffset:
          return false
      elif right.startOffset == right.endOffset:
        if right.startOffset > left.startOffset and right.startOffset < left.endOffset:
          return false
      elif max(left.startOffset, right.startOffset) <
          min(left.endOffset, right.endOffset):
        return false
  true

proc combineImportEdits(additions, removals: seq[ImportEdit]): seq[ImportEdit] =
  var consumedAdditions = newSeq[bool](additions.len)
  for removal in removals:
    var merged = removal
    var covered = false
    for index, addition in additions:
      if consumedAdditions[index]:
        continue
      if addition.startOffset <= removal.startOffset and
          addition.endOffset >= removal.endOffset and
          addition.endOffset > addition.startOffset:
        covered = true
      elif addition.startOffset == addition.endOffset and
          addition.startOffset >= removal.startOffset and
          addition.startOffset <= removal.endOffset:
        consumedAdditions[index] = true
        if addition.startOffset == removal.endOffset:
          merged.newText.add addition.newText
        else:
          merged.newText = addition.newText & merged.newText
    if not covered:
      result.add merged
  for index, addition in additions:
    if not consumedAdditions[index]:
      result.add addition

proc validatesEdits(
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

proc renderImportAdditions(
    source: string,
    imports: SourceImports,
    candidates: seq[PlannedImport],
    stdlib: StdlibMap,
    options: OrganizeOptions,
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
        sourceImportInsertion(source, imports, orderedOther[0].candidate, stdlib)
      result.add ImportEdit(
        startOffset: otherInsertion,
        endOffset: otherInsertion,
        newText: renderNewImports(otherCandidates, options.useStdPrefix, newline),
      )
  elif candidates.len > 0:
    var orderedModules = candidates
    orderedModules.sort(plannedImportOrder)
    let insertion =
      sourceImportInsertion(source, imports, orderedModules[0].candidate, stdlib)
    var newText = renderNewImports(candidates, options.useStdPrefix, newline)
    var physicalImportCount = 0
    for item in imports.imports:
      if not item.synthetic:
        inc physicalImportCount
    if physicalImportCount == 0:
      newText.add newline
    result.add ImportEdit(
      startOffset: insertion, endOffset: insertion, newText: newText
    )

proc hasLocalDefinition(info: SourceImports, name: string): bool =
  for definedName in info.localDefinitions:
    if sameIdentifier(definedName, name):
      return true

proc forBindingState(
    index: SourceIndex, name: string, tokenIndex: int
): NativeBindingState =
  if index == nil:
    return nativeUnknown
  let wanted = identifierKey(name)
  for forIndex, forToken in index.parsed.tokens:
    if not forToken.hasKeywordRole(roleForBinding):
      continue
    var cursor = forIndex + 1
    var separator = -1
    var foundName = false
    while cursor < index.parsed.tokens.len and
        index.parsed.tokens[cursor].line == forToken.line:
      let token = index.parsed.tokens[cursor]
      if index.parsed.tokens.tokenTextEquals(token, "in") or
          index.parsed.tokens.tokenTextEquals(token, "=") or
          index.parsed.tokens.tokenTextEquals(token, ":"):
        separator = cursor
        break
      if token.kind == tkIdentifier and not isNimKeyword(token) and
          identifierKey(index.parsed.tokens, token) == wanted:
        foundName = true
      inc cursor
    if not foundName:
      continue
    if tokenIndex <= forIndex or separator < 0 or tokenIndex <= separator:
      return nativeUnknown
    if index.parsed.tokens[tokenIndex].line == forToken.line:
      cursor = separator + 1
      while cursor < index.parsed.tokens.len and
          index.parsed.tokens[cursor].line == forToken.line and
          not index.parsed.tokens.tokenTextEquals(index.parsed.tokens[cursor], ":")
      :
        inc cursor
      if tokenIndex >= cursor:
        return nativeBound
      return nativeUnknown
    if index.parsed.tokens[tokenIndex].column > forToken.column:
      return nativeBound
    return nativeUnknown
  return nativeNoBinding

proc nativeBinding(
    info: SourceImports, index: SourceIndex, name: string, tokenIndex: int
): NativeBindingState =
  if index == nil or tokenIndex < 0 or tokenIndex >= index.parsed.tokens.len:
    return nativeUnknown
  if index.bindingsReady:
    let binding = index.resolveBinding(uint32(tokenIndex))
    case binding.state
    of bindingResolved:
      return nativeBound
    of bindingAmbiguous:
      return nativeUnknown
    of bindingUnknown:
      discard
  var found = false
  for symbol in index.symbols:
    let symbolIndex = int(symbol.nameToken)
    if symbolIndex < 0 or symbolIndex >= index.parsed.tokens.len or
        identifierKey(index.parsed.tokens, index.parsed.tokens[symbolIndex]) !=
        identifierKey(name):
      continue
    found = true
    if symbolIndex >= tokenIndex:
      return nativeUnknown
    result = nativeBound

  let occurrenceScope = index.scopes.innermostScopeAt(uint32(tokenIndex))
  for declaration in index.scopes.declarations:
    let declarationIndex = int(declaration.nameToken)
    if declarationIndex < 0 or declarationIndex >= index.parsed.tokens.len or
        identifierKey(index.parsed.tokens, index.parsed.tokens[declarationIndex]) !=
        identifierKey(name) or
        not index.scopes.isScopeAncestor(declaration.scope, occurrenceScope):
      continue
    found = true
    if declarationIndex >= tokenIndex:
      return nativeUnknown
    result = nativeBound

  let forBinding = forBindingState(index, name, tokenIndex)
  if forBinding != nativeNoBinding:
    return forBinding
  if found:
    return
  if hasLocalDefinition(info, name):
    return nativeUnknown
  return nativeNoBinding

proc nativeNameUse(
    info: SourceImports, index: SourceIndex, itemEnd: int, name: string
): NativeModuleUse =
  for occurrence in index.occurrences.identifiers:
    let tokenIndex = int(occurrence.token)
    if tokenIndex < 0 or tokenIndex >= index.parsed.tokens.len:
      continue
    let token = index.parsed.tokens[tokenIndex]
    if token.startOffset <= itemEnd or
        identifierKey(index.parsed.tokens, token) != identifierKey(name):
      continue
    if tokenIndex > 0 and
        index.parsed.tokens.tokenTextEquals(index.parsed.tokens[tokenIndex - 1], "."):
      continue
    case nativeBinding(info, index, name, tokenIndex)
    of nativeBound:
      discard
    of nativeUnknown:
      return nativeModuleUseUnknown
    of nativeNoBinding:
      if hasLocalDefinition(info, name):
        return nativeModuleUseUnknown
      return nativeModuleUseFound
  nativeModuleUseNone

proc nativeUnqualifiedUse(stdlib: StdlibMap, name, module: string): NativeModuleUse =
  let resolved = stdlib.resolveUniqueCandidate(name, "", -1)
  case resolved.state
  of candidateResolutionMissing:
    nativeModuleUseNone
  of candidateResolutionAmbiguous:
    for candidate in stdlib.candidatesFor(name, "", -1):
      if sameModule(candidate.module, module):
        return nativeModuleUseUnknown
    nativeModuleUseNone
  of candidateResolutionResolved:
    if sameModule(resolved.candidate.module, module):
      nativeModuleUseFound
    else:
      nativeModuleUseNone

proc nativeImplicitEquivalent(
    stdlib: StdlibMap, name, qualifier: string, arity: int
): bool =
  let candidates = stdlib.candidatesFor(name, qualifier, arity)
  var implicitCount = 0
  for candidate in candidates:
    if stdlib.implicitModule(candidate.module):
      inc implicitCount
  if implicitCount == 0:
    return false
  for candidate in candidates:
    if stdlib.implicitModule(candidate.module):
      continue
    var equivalent = false
    for implicit in candidates:
      if stdlib.implicitModule(implicit.module) and candidate.kind == implicit.kind and
          candidate.arity == implicit.arity and candidate.signature == implicit.signature:
        equivalent = true
        break
    if not equivalent:
      return false
  true

proc projectModuleResolution(
    project: SurfaceIndex, catalog: ModuleCatalog, owner, reference: string
): ModuleResolution =
  if project == nil:
    result.kind = moduleUnknown
    return
  if catalog != nil:
    return catalog.resolveModuleName(owner, reference)
  let module = project.moduleForReference(reference, owner)
  if module.len == 0:
    result.kind = if project.universeIsComplete: moduleMissing else: moduleUnknown
    return
  result.kind = moduleResolved
  result.module = module

proc nativeProjectModuleUse(
    project: SurfaceIndex, catalog: ModuleCatalog, owner, name, module: string
): NativeModuleUse =
  let resolved = projectModuleResolution(project, catalog, owner, module)
  case resolved.kind
  of moduleResolved:
    let binding = project.lookupInModule(resolved.module, name)
    case binding.kind
    of surfaceResolved: nativeModuleUseFound
    of surfaceUnresolved: nativeModuleUseNone
    of surfaceAmbiguous, surfaceUnknown: nativeModuleUseUnknown
  of moduleMissing:
    nativeModuleUseNone
  of moduleAmbiguous, moduleUnknown:
    nativeModuleUseUnknown

proc projectCandidate(
    project: SurfaceIndex, catalog: ModuleCatalog, owner, name, qualifier: string
): tuple[state: NativeCandidateState, candidate: SymbolCandidate] =
  if project == nil:
    return
  let resolution = project.resolveSurfaceReference(catalog, name, qualifier, owner)
  case resolution.kind
  of surfaceResolved:
    let module = project.moduleForResolution(resolution)
    if module.len == 0:
      result.state = nativeCandidateUnknown
      return
    result.state = nativeCandidateResolved
    result.candidate = SymbolCandidate(
      module: module,
      name: name,
      kind: "",
      arity: -1,
      signature: "",
      priority: candidateDefault,
    )
  of surfaceUnresolved:
    result.state = nativeCandidateNone
  of surfaceAmbiguous:
    result.state = nativeCandidateAmbiguous
  of surfaceUnknown:
    result.state = nativeCandidateUnknown

proc nativeModuleUsed(
    info: SourceImports,
    index: SourceIndex,
    item: ImportInfo,
    stdlib: StdlibMap,
    project: SurfaceIndex,
    catalog: ModuleCatalog,
    owner: string,
): NativeModuleUse =
  let module = canonicalModule(item.module)
  let qualifier =
    if item.alias.len > 0:
      item.alias
    else:
      moduleLeaf(item.module)
  for occurrence in index.occurrences.identifiers:
    let tokenIndex = int(occurrence.token)
    if tokenIndex < 0 or tokenIndex >= index.parsed.tokens.len:
      continue
    let token = index.parsed.tokens[tokenIndex]
    if token.startOffset <= item.endOffset:
      continue

    if tokenIndex >= 2 and
        index.parsed.tokens.tokenTextEquals(index.parsed.tokens[tokenIndex - 1], "."):
      let qualifierIndex = tokenIndex - 2
      let qualifierToken = index.parsed.tokens[qualifierIndex]
      if qualifierToken.kind == tkIdentifier and (
        qualifierIndex == 0 or
        not index.parsed.tokens.tokenTextEquals(
          index.parsed.tokens[qualifierIndex - 1], "."
        )
      ) and sameIdentifier(index.parsed.tokens.tokenText(qualifierToken), qualifier):
        let binding = nativeBinding(
          info, index, index.parsed.tokens.tokenText(qualifierToken), qualifierIndex
        )
        if binding == nativeUnknown:
          return nativeModuleUseUnknown
        if binding == nativeNoBinding:
          return nativeModuleUseFound
      continue

    if tokenIndex > 0 and
        index.parsed.tokens.tokenTextEquals(index.parsed.tokens[tokenIndex - 1], ".") or
        tokenIndex + 1 < index.parsed.tokens.len and
        index.parsed.tokens.tokenTextEquals(index.parsed.tokens[tokenIndex + 1], "."):
      continue
    let name = index.parsed.tokens.tokenText(token)
    let binding = nativeBinding(info, index, name, tokenIndex)
    if binding == nativeUnknown:
      return nativeModuleUseUnknown
    if binding == nativeNoBinding:
      let use =
        if module.startsWith("std/"):
          nativeUnqualifiedUse(stdlib, name, module)
        else:
          nativeProjectModuleUse(project, catalog, owner, name, module)
      if use != nativeModuleUseNone:
        return use
  nativeModuleUseNone

proc nativeImportRemovalPlan(
    info: SourceImports,
    index: SourceIndex,
    stdlib: StdlibMap,
    project: SurfaceIndex,
    catalog: ModuleCatalog,
    owner: string,
): tuple[state: NativeRemovalState, plan: ImportRemovalPlan] =
  result.plan = initImportRemovalPlan(info)
  if not index.nativeIndexSafe():
    return
  for itemIndex, item in info.imports:
    let module = canonicalModule(item.module)
    if item.keep:
      continue
    case item.form
    of importModule:
      if module.startsWith("std/"):
        if module notin stdlib.modules:
          return
      elif project == nil or not project.universeIsComplete:
        return
      else:
        let resolution = projectModuleResolution(project, catalog, owner, item.module)
        if resolution.kind != moduleResolved:
          return
      case nativeModuleUsed(info, index, item, stdlib, project, catalog, owner)
      of nativeModuleUseFound:
        discard
      of nativeModuleUseNone:
        result.plan.whole.incl itemIndex
      of nativeModuleUseUnknown:
        return
    of fromModule:
      if item.importedSymbols.len == 0:
        return
      for imported in item.importedSymbols:
        case nativeNameUse(info, index, item.endOffset, imported.name)
        of nativeModuleUseFound:
          discard
        of nativeModuleUseNone:
          result.plan.symbols[itemIndex].incl imported.name
        of nativeModuleUseUnknown:
          return
  promoteEmptyFromImports(info, result.plan)
  result.state = nativeRemovalReady

proc nativeProvidesName(info: SourceImports, name: string): bool =
  for item in info.imports:
    if item.synthetic or item.conditional or item.form != fromModule:
      continue
    for imported in item.importedSymbols:
      if sameIdentifier(imported.name, name):
        return true

proc nativeImportAdditions(
    source: string,
    info: SourceImports,
    index: SourceIndex,
    stdlib: StdlibMap,
    project: SurfaceIndex,
    catalog: ModuleCatalog,
    owner: string,
): tuple[safe: bool, candidates: seq[PlannedImport]] =
  result.safe = true
  for occurrence in index.occurrences.identifiers:
    let tokenIndex = int(occurrence.token)
    if tokenIndex < 0 or tokenIndex >= index.parsed.tokens.len:
      continue
    let token = index.parsed.tokens[tokenIndex]

    var name = index.parsed.tokens.tokenText(token)
    var qualifier = ""
    if tokenIndex >= 2 and
        index.parsed.tokens.tokenTextEquals(index.parsed.tokens[tokenIndex - 1], "."):
      let qualifierIndex = tokenIndex - 2
      if qualifierIndex < 0 or index.parsed.tokens[qualifierIndex].kind != tkIdentifier or
      (
        qualifierIndex > 0 and
        index.parsed.tokens.tokenTextEquals(
          index.parsed.tokens[qualifierIndex - 1], "."
        )
      ):
        continue
      qualifier = index.parsed.tokens.tokenText(index.parsed.tokens[qualifierIndex])
      let binding = nativeBinding(info, index, qualifier, qualifierIndex)
      if binding == nativeBound:
        continue
      if binding == nativeUnknown:
        result.safe = false
        return
    elif tokenIndex > 0 and
        index.parsed.tokens.tokenTextEquals(index.parsed.tokens[tokenIndex - 1], ".") or
        tokenIndex + 1 < index.parsed.tokens.len and
        index.parsed.tokens.tokenTextEquals(index.parsed.tokens[tokenIndex + 1], "."):
      continue

    let arity = callArity(info, source, tokenIndex)
    let resolved = stdlib.resolveUniqueCandidate(name, qualifier, arity)
    if qualifier.len == 0:
      let binding = nativeBinding(info, index, name, tokenIndex)
      if binding == nativeBound:
        continue
      if binding == nativeUnknown:
        result.safe = false
        return
    var projectResult: tuple[state: NativeCandidateState, candidate: SymbolCandidate]
    if project == nil or project.universeIsComplete():
      projectResult = projectCandidate(project, catalog, owner, name, qualifier)
    elif stdlib.nativeImplicitEquivalent(name, qualifier, arity):
      projectResult.state = nativeCandidateNone
    else:
      projectResult.state = nativeCandidateUnknown
    var candidate: SymbolCandidate
    var candidateSource = nativeCandidateStdlibSource
    case projectResult.state
    of nativeCandidateResolved:
      if resolved.state != candidateResolutionMissing:
        result.safe = false
        return
      candidate = projectResult.candidate
      candidateSource = nativeCandidateProjectSource
    of nativeCandidateNone:
      case resolved.state
      of candidateResolutionMissing:
        continue
      of candidateResolutionAmbiguous:
        if stdlib.nativeImplicitEquivalent(name, qualifier, arity):
          continue
        result.safe = false
        return
      of candidateResolutionResolved:
        candidate = resolved.candidate
    of nativeCandidateAmbiguous, nativeCandidateUnknown:
      result.safe = false
      return

    case candidateSource
    of nativeCandidateStdlibSource:
      if stdlib.implicitModule(candidate.module):
        continue
      if candidate.module.len == 0 or
          not canonicalModule(candidate.module).startsWith("std/") or
          canonicalModule(candidate.module) notin stdlib.modules:
        result.safe = false
        return
    of nativeCandidateProjectSource:
      if project == nil or not project.universeIsComplete:
        result.safe = false
        return
      let module = projectModuleResolution(project, catalog, owner, candidate.module)
      if module.kind != moduleResolved or not sameModule(
        module.module, candidate.module
      ):
        result.safe = false
        return
      if owner.len > 0 and sameModule(candidate.module, owner):
        continue
    let existing = findExistingModule(info, candidate.module)
    if nativeProvidesName(info, name) or
        (qualifier.len > 0 and info.providesQualifier(qualifier)) or existing.plain >= 0 or
        existing.aliased >= 0:
      continue
    addUniqueModule(result.candidates, candidate, false)

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
  result.handled = true
  let activeInfo = activeImportInfo(info, removalPlan)
  let newline = if source.contains("\r\n"): "\r\n" else: "\n"
  result.edits = renderImportAdditions(
    source, activeInfo, additions.candidates, stdlib, options, newline
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

  if newModules.len > 0:
    for edit in renderImportAdditions(
      source, activeInfo, newModules, stdlib, options, newline
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
  let edits = organizeSourceWithIndex(filePath, source, indexSource(source), options)
  if edits.len == 0:
    return false
  let organized = applyEdits(source, edits)
  if organized == source:
    return false
  writeFile(filePath, organized)
  true
