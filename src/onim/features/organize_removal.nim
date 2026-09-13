import std/[algorithm, sets, strutils]

import ../index/source_index
import ../index/surfaces
import ../semantic/compiler_api
import ../session/module_catalog
import ../stdlib/map
import ../syntax/imports
import ../syntax/module_names
import ../syntax/source_lines
import ./organize_planning
import ./organize_native_usage
import ./organize_unused
import ./organize_edits
import ./organize_import_text

type
  ImportRemovalPlan* = object
    whole*: HashSet[int]
    symbols*: seq[HashSet[string]]

  NativeRemovalState* = enum
    nativeRemovalUnsupported
    nativeRemovalReady

proc initImportRemovalPlan*(imports: SourceImports): ImportRemovalPlan =
  result.whole = initHashSet[int]()
  result.symbols = newSeq[HashSet[string]](imports.imports.len)
  for index in 0 ..< result.symbols.len:
    result.symbols[index] = initHashSet[string]()

proc hasImportRemovals*(plan: ImportRemovalPlan): bool =
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

proc collectUnusedImportPlan*(
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

proc activeImportInfo*(imports: SourceImports, plan: ImportRemovalPlan): SourceImports =
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

proc nativeImportRemovalPlan*(
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
    if item.keep or item.conditional:
      continue
    case item.form
    of importModule:
      if stdlib.knownModule(module):
        discard
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

proc unusedImportEdits*(
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

proc groupedStdRemovalEdits*(
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
