import std/[algorithm, hashes, os, sets, strutils, tables]

import ../semantic/compiler_api
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

proc moduleLeaf(module: string): string =
  let normalized = canonicalModule(module)
  if normalized.len == 0:
    return
  let slash = normalized.rfind('/')
  if slash >= 0 and slash + 1 < normalized.len:
    normalized[slash + 1 .. ^1]
  else:
    normalized

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

proc tokenInPhysicalImport(imports: SourceImports, token: Token): bool =
  for item in imports.imports:
    if not item.synthetic and token.startOffset >= item.startOffset and
        token.endOffset <= item.endOffset:
      return true

proc hasIncludedSource(imports: SourceImports): bool =
  for token in imports.tokens:
    if token.text == "include":
      return true

proc importedNameUsed(
    source: string, imports: SourceImports, item: ImportInfo, name: string
): bool =
  for tokenIndex, token in imports.tokens:
    if token.kind != tkIdentifier or token.text != name or
        token.startOffset <= item.endOffset or tokenInPhysicalImport(imports, token):
      continue
    if tokenIndex > 0 and imports.tokens[tokenIndex - 1].text == ".":
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

  for index, item in imports.imports:
    if item.form != fromModule or result.plan.symbols[index].len == 0:
      continue
    var allSymbolsRemoved = item.importedSymbols.len > 0
    for symbol in item.importedSymbols:
      if symbol.name notin result.plan.symbols[index]:
        allSymbolsRemoved = false
        break
    if allSymbolsRemoved:
      result.plan.symbols[index].clear
      result.plan.whole.incl index

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
    var stdCandidates: seq[PlannedImport] = @[]
    var otherCandidates: seq[PlannedImport] = @[]
    for planned in newModules:
      if not planned.fromImport and
          canonicalModule(planned.candidate.module).startsWith("std/"):
        stdCandidates.add planned
      else:
        otherCandidates.add planned

    let existingStd = groupableStdImports(source, activeInfo, stdlib)
    if stdCandidates.len > 0 and existingStd.len > 0:
      var existingStdModules: seq[string] = @[]
      for statement in existingStd:
        for module in stdModulesOnStatement(activeInfo, statement, stdlib):
          addUniqueStdModule(existingStdModules, module)

      let insertion = sourceImportInsertion(
        source, activeInfo, stdCandidates[0].candidate, stdlib, true
      )
      let replacementEnd = statementEndWithNewline(source, existingStd[0])
      var mergeOtherCandidates = false
      if otherCandidates.len > 0:
        var orderedOther = otherCandidates
        orderedOther.sort(plannedImportOrder)
        let otherInsertion =
          sourceImportInsertion(source, activeInfo, orderedOther[0].candidate, stdlib)
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
          sourceImportInsertion(source, activeInfo, orderedOther[0].candidate, stdlib)
        result.add ImportEdit(
          startOffset: otherInsertion,
          endOffset: otherInsertion,
          newText: renderNewImports(otherCandidates, options.useStdPrefix, newline),
        )
    else:
      var orderedModules = newModules
      orderedModules.sort(plannedImportOrder)
      let insertion =
        sourceImportInsertion(source, activeInfo, orderedModules[0].candidate, stdlib)
      var newText = renderNewImports(newModules, options.useStdPrefix, newline)
      var physicalImportCount = 0
      for item in activeInfo.imports:
        if not item.synthetic:
          inc physicalImportCount
      if physicalImportCount == 0:
        newText.add newline
      result.add ImportEdit(
        startOffset: insertion, endOffset: insertion, newText: newText
      )

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
