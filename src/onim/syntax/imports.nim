import std/[sets, strutils]

import ./import_lines
import ./local_definitions
import ./module_names
import ./statement_ranges
import ./tokens
import ./lexer

type
  ImportForm* = enum
    importModule
    fromModule

  ConditionalImportDisposition* = enum
    importUnconditional
    importConditionalActive
    importConditionalInactive
    importConditionalUnknown

  ImportSymbol* = object
    name*: string
    startOffset*: int
    endOffset*: int

  ImportInfo* = object
    form*: ImportForm
    module*: string
    alias*: string
    imported*: HashSet[string]
    excluded*: HashSet[string]
    importedSymbols*: seq[ImportSymbol]
    startOffset*: int
    endOffset*: int
    moduleStartOffset*: int
    moduleEndOffset*: int
    diagnosticNameStartOffset*: int
    diagnosticNameEndOffset*: int
    itemStartOffset*: int
    itemEndOffset*: int
    separatorStartOffset*: int
    line*: int
    indent*: string
    synthetic*: bool
    conditional*: bool
    keep*: bool

  FromImportBindingKind* = enum
    fromImportNone
    fromImportPlain
    fromImportAlias
    fromImportUnsupported

  FromImportBinding* = object
    kind*: FromImportBindingKind
    providerName*: string

  SourceImports* = object
    tokens*: TokenStore
    imports*: seq[ImportInfo]
    localDefinitions*: HashSet[string]
    availableNames*: HashSet[string]
    qualifiedNames*: HashSet[string]

proc conditionalHeaderDisposition(line: string): ConditionalImportDisposition =
  var compact = newStringOfCap(line.len)
  for character in line:
    if character == '#':
      break
    if character notin {' ', '\t', '\r'}:
      compact.add character
  case compact
  of "whendefined(posix):", "whendefined(linux):": importConditionalActive
  of "whendefined(windows):": importConditionalInactive
  else: importConditionalUnknown

proc conditionalImportDisposition*(
  imports: SourceImports, item: ImportInfo
): ConditionalImportDisposition {.gcsafe.}

proc addFromImportedName(
    info: var ImportInfo, tokens: TokenStore, cursor: var int, finish: int
) =
  while cursor < finish and
      (tokens[cursor].kind != tkIdentifier or tokens[cursor].isKeyword(kwAs)):
    inc cursor
  if cursor >= finish or tokens[cursor].isKeyword(kwExcept):
    return
  let start = tokens[cursor].startOffset
  var name = tokens.tokenText(tokens[cursor])
  var finishOffset = tokens[cursor].endOffset
  inc cursor
  if cursor < finish and tokens[cursor].isKeyword(kwAs):
    inc cursor
    if cursor < finish and tokens[cursor].kind == tkIdentifier:
      name = tokens.tokenText(tokens[cursor])
      finishOffset = tokens[cursor].endOffset
      inc cursor
  info.imported.incl name
  info.importedSymbols.add ImportSymbol(
    name: name, startOffset: start, endOffset: finishOffset
  )

proc fromImportHasExcept(tokens: TokenStore, item: ImportInfo): bool {.inline.} =
  for token in tokens:
    if token.startOffset < item.startOffset or token.endOffset > item.endOffset:
      continue
    if token.isKeyword(kwExcept):
      return true

proc fromImportBinding*(
    tokens: TokenStore, source: string, item: ImportInfo, localName: string
): FromImportBinding =
  if item.form != fromModule:
    return
  for imported in item.importedSymbols:
    if not sameIdentifier(imported.name, localName):
      continue
    result.kind = fromImportUnsupported
    if item.synthetic or item.conditional or item.excluded.len > 0 or
        fromImportHasExcept(tokens, item):
      return
    if imported.startOffset < 0 or imported.endOffset <= imported.startOffset or
        imported.endOffset > source.len:
      return
    var firstToken = -1
    var tokenCount = 0
    for tokenIndex, token in tokens:
      if token.startOffset < imported.startOffset or token.endOffset > imported.endOffset:
        continue
      if firstToken < 0:
        firstToken = tokenIndex
      inc tokenCount
    if tokenCount == 1 and firstToken >= 0 and tokens[firstToken].kind == tkIdentifier:
      result.kind = fromImportPlain
      result.providerName =
        source[imported.startOffset ..< imported.endOffset].strip(chars = {'`'})
    elif tokenCount == 3 and firstToken >= 0:
      let original = tokens[firstToken]
      let asToken = tokens[firstToken + 1]
      let alias = tokens[firstToken + 2]
      if original.kind == tkIdentifier and asToken.isKeyword(kwAs) and
          alias.kind == tkIdentifier:
        result.kind = fromImportAlias
        result.providerName = tokens.tokenText(original)
    return

proc parseImport(
    tokens: TokenStore, source: string, index: int
): tuple[items: seq[ImportInfo], next: int, uncertainty: set[StatementUncertainty]] =
  let statement = statementRange(tokens, index)
  let endIndex = statement.past
  result.next = endIndex
  result.uncertainty = statement.uncertainty
  if statementHasMissingOperand(tokens, index, endIndex):
    result.uncertainty.incl statementIncomplete
  if result.uncertainty != {}:
    return
  let keep = keepImport(source, tokens, index, endIndex)
  var cursor = index + 1
  var prefix = ""
  while cursor < endIndex and not tokens.tokenTextEquals(tokens[cursor], "[") and
      not tokens[cursor].isKeyword(kwAs) and not tokens[cursor].isKeyword(kwExcept) and
      not tokens.tokenTextEquals(tokens[cursor], ",")
  :
    prefix.add tokens.tokenText(tokens[cursor])
    inc cursor
  prefix = prefix.strip(chars = {' ', '\t'})
  if cursor < endIndex and tokens.tokenTextEquals(tokens[cursor], "["):
    inc cursor
    while cursor < endIndex and not tokens.tokenTextEquals(tokens[cursor], "]"):
      if tokens[cursor].kind == tkIdentifier:
        var module = prefix
        if module.len > 0 and not module.endsWith("/"):
          module.add '/'
        module.add tokens.tokenText(tokens[cursor])
        var item = ImportInfo(
          form: importModule,
          module: module,
          imported: initHashSet[string](),
          excluded: initHashSet[string](),
          moduleStartOffset: tokens[cursor].startOffset,
          moduleEndOffset: tokens[cursor].endOffset,
          diagnosticNameStartOffset: tokens[cursor].startOffset,
          diagnosticNameEndOffset: tokens[cursor].endOffset,
          itemStartOffset: tokens[cursor].startOffset,
          itemEndOffset: tokens[cursor].endOffset,
          startOffset: tokens[index].startOffset,
          endOffset: tokens[endIndex - 1].endOffset,
          line: tokens[index].line,
          indent: lineIndent(source, tokens[index].startOffset),
          keep: keep,
        )
        result.items.add item
      inc cursor
  else:
    cursor = index + 1
    while cursor < endIndex:
      if tokens[cursor].isKeyword(kwExcept):
        break
      if tokens.tokenTextEquals(tokens[cursor], ",") or tokens[cursor].isKeyword(kwAs):
        inc cursor
        continue
      let moduleStart = cursor
      while cursor < endIndex and not tokens.tokenTextEquals(tokens[cursor], ",") and
          not tokens[cursor].isKeyword(kwAs) and not tokens[cursor].isKeyword(kwExcept):
        inc cursor
      let module = moduleText(tokens, moduleStart, cursor)
      if module.len == 0:
        continue
      let separatorStart =
        if result.items.len > 0 and moduleStart > 0 and
            tokens.tokenTextEquals(tokens[moduleStart - 1], ","):
          tokens[moduleStart - 1].startOffset
        else:
          -1
      var item = ImportInfo(
        form: importModule,
        module: module,
        imported: initHashSet[string](),
        excluded: initHashSet[string](),
        moduleStartOffset: tokens[moduleStart].startOffset,
        moduleEndOffset: tokens[cursor - 1].endOffset,
        diagnosticNameStartOffset: tokens[moduleStart].startOffset,
        diagnosticNameEndOffset: tokens[cursor - 1].endOffset,
        itemStartOffset: tokens[moduleStart].startOffset,
        itemEndOffset: tokens[cursor - 1].endOffset,
        separatorStartOffset: separatorStart,
        startOffset: tokens[index].startOffset,
        endOffset: tokens[endIndex - 1].endOffset,
        line: tokens[index].line,
        indent: lineIndent(source, tokens[index].startOffset),
        keep: keep,
      )
      if cursor < endIndex and tokens[cursor].isKeyword(kwAs):
        inc cursor
        if cursor < endIndex and tokens[cursor].kind == tkIdentifier:
          item.alias = tokens.tokenText(tokens[cursor])
          item.diagnosticNameStartOffset = tokens[cursor].startOffset
          item.diagnosticNameEndOffset = tokens[cursor].endOffset
          item.itemEndOffset = tokens[cursor].endOffset
          inc cursor
      result.items.add item

  # `except` belongs to the module immediately before it, including bracketed
  # imports. It is intentionally kept separate from imported names.
  var exceptIndex = index + 1
  while exceptIndex < endIndex and not tokens[exceptIndex].isKeyword(kwExcept):
    inc exceptIndex
  if exceptIndex < endIndex and result.items.len > 0:
    var cursorExcept = exceptIndex + 1
    while cursorExcept < endIndex:
      if tokens[cursorExcept].kind == tkIdentifier:
        result.items[^1].excluded.incl tokens.tokenText(tokens[cursorExcept])
      inc cursorExcept
    result.items[^1].itemEndOffset = tokens[endIndex - 1].endOffset

proc parseFrom(
    tokens: TokenStore, source: string, index: int
): tuple[
  item: ImportInfo, next: int, valid: bool, uncertainty: set[StatementUncertainty]
] =
  let statement = statementRange(tokens, index)
  let endIndex = statement.past
  result.next = endIndex
  result.uncertainty = statement.uncertainty
  if not fromStatementComplete(tokens, index, endIndex):
    result.uncertainty.incl statementIncomplete
  if result.uncertainty != {}:
    return
  var importIndex = index + 1
  while importIndex < endIndex and not tokens[importIndex].isKeyword(kwImport):
    inc importIndex
  if importIndex >= endIndex:
    return
  var info = ImportInfo(
    form: fromModule,
    module: moduleText(tokens, index + 1, importIndex),
    imported: initHashSet[string](),
    excluded: initHashSet[string](),
    startOffset: tokens[index].startOffset,
    endOffset: tokens[endIndex - 1].endOffset,
    line: tokens[index].line,
    indent: lineIndent(source, tokens[index].startOffset),
    keep: keepImport(source, tokens, index, endIndex),
  )
  if info.module.len > 0:
    info.moduleStartOffset = tokens[index + 1].startOffset
    info.moduleEndOffset = tokens[importIndex - 1].endOffset
    info.diagnosticNameStartOffset = info.moduleStartOffset
    info.diagnosticNameEndOffset = info.moduleEndOffset
  var cursor = importIndex + 1
  while cursor < endIndex and not tokens[cursor].isKeyword(kwExcept):
    info.addFromImportedName(tokens, cursor, endIndex)
    while cursor < endIndex and not tokens.tokenTextEquals(tokens[cursor], ",") and
        not tokens[cursor].isKeyword(kwExcept):
      inc cursor
    if cursor < endIndex and tokens.tokenTextEquals(tokens[cursor], ","):
      inc cursor
  result.item = info
  result.valid = info.module.len > 0

proc parseSourceImports*(source: string): SourceImports =
  let tokens = lex(source)
  let lines = source.splitLines
  result.localDefinitions = collectDefinitions(tokens)
  result.availableNames = initHashSet[string]()
  result.qualifiedNames = initHashSet[string]()
  var index = 0
  while index < tokens.len:
    if tokens[index].isKeyword(kwImport):
      let parsed = parseImport(tokens, source, index)
      if parsed.uncertainty == {}:
        for parsedItem in parsed.items:
          var item = parsedItem
          item.conditional = conditionalImport(lines, tokens[index])
          result.imports.add item
      index = max(index + 1, parsed.next)
    elif tokens[index].isKeyword(kwFrom):
      let parsed = parseFrom(tokens, source, index)
      if parsed.valid and parsed.uncertainty == {}:
        var item = parsed.item
        item.conditional = conditionalImport(lines, tokens[index])
        result.imports.add item
      index = max(index + 1, parsed.next)
    else:
      inc index
  result.tokens = tokens
  for item in result.imports:
    let disposition = result.conditionalImportDisposition(item)
    if disposition notin {importUnconditional, importConditionalActive}:
      continue
    case item.form
    of importModule:
      if item.alias.len > 0:
        result.qualifiedNames.incl item.alias
      else:
        result.qualifiedNames.incl moduleLeaf(item.module)
    of fromModule:
      for name in item.imported:
        result.availableNames.incl name
  for name in result.localDefinitions:
    result.availableNames.incl name

proc conditionalImportDisposition*(
    imports: SourceImports, item: ImportInfo
): ConditionalImportDisposition {.gcsafe.} =
  if not item.conditional:
    return importUnconditional
  if imports.tokens.sourceText.len == 0 or item.synthetic or item.form != importModule or
      item.excluded.len > 0:
    return importConditionalUnknown

  let source = imports.tokens.sourceText
  let bodyStart = conditionalLineStart(source, item.startOffset)
  let bodyIndent = item.indent.len
  if bodyIndent == 0:
    return importConditionalUnknown

  var headerStart = conditionalPreviousLine(source, bodyStart)
  while headerStart >= 0:
    let headerPast = conditionalLinePast(source, headerStart)
    if conditionalLineText(source, headerStart, headerPast).len == 0:
      headerStart = conditionalPreviousLine(source, headerStart)
      continue
    let headerIndent = conditionalLineIndent(source, headerStart, headerPast)
    if headerIndent < bodyIndent:
      if headerIndent != 0:
        return importConditionalUnknown
      break
    headerStart = conditionalPreviousLine(source, headerStart)
  if headerStart < 0:
    return importConditionalUnknown

  let headerPast = conditionalLinePast(source, headerStart)
  result =
    conditionalHeaderDisposition(conditionalLineText(source, headerStart, headerPast))
  if result == importConditionalUnknown:
    return

  var cursor = conditionalNextLine(source, headerPast)
  var itemFound = false
  while cursor < source.len:
    let past = conditionalLinePast(source, cursor)
    let text = conditionalLineText(source, cursor, past)
    if text.len == 0 or text[0] == '#':
      cursor = conditionalNextLine(source, past)
      continue
    let indent = conditionalLineIndent(source, cursor, past)
    if indent <= 0:
      if indent == 0 and (text.startsWith("elif ") or text.startsWith("else:")):
        return importConditionalUnknown
      break
    if indent != bodyIndent or not text.startsWith("import ") or text.contains(';'):
      return importConditionalUnknown

    var lineImport = false
    for peer in imports.imports:
      if peer.startOffset < cursor or peer.startOffset >= past:
        continue
      lineImport = true
      if not peer.conditional or peer.synthetic or peer.form != importModule or
          peer.excluded.len > 0:
        return importConditionalUnknown
    if not lineImport:
      return importConditionalUnknown
    if item.startOffset >= cursor and item.startOffset < past:
      itemFound = true
    cursor = conditionalNextLine(source, past)
  if not itemFound:
    return importConditionalUnknown

proc conditionalTokenDisposition*(
    imports: SourceImports, token: Token
): ConditionalImportDisposition {.gcsafe.} =
  let source = imports.tokens.sourceText
  for item in imports.imports:
    if not item.conditional:
      continue
    let disposition = imports.conditionalImportDisposition(item)
    if disposition == importConditionalUnknown:
      continue
    let bodyStart = conditionalLineStart(source, item.startOffset)
    var headerStart = conditionalPreviousLine(source, bodyStart)
    while headerStart >= 0:
      let headerPast = conditionalLinePast(source, headerStart)
      let text = conditionalLineText(source, headerStart, headerPast)
      if text.len > 0:
        if conditionalLineIndent(source, headerStart, headerPast) < item.indent.len:
          if token.startOffset >= headerStart and token.endOffset <= headerPast:
            return disposition
          break
      headerStart = conditionalPreviousLine(source, headerStart)
  importConditionalUnknown

proc cloneSourceImports*(source: SourceImports): SourceImports =
  result.tokens = source.tokens
  result.localDefinitions = initHashSet[string]()
  result.availableNames = initHashSet[string]()
  result.qualifiedNames = initHashSet[string]()
  for name in source.localDefinitions:
    result.localDefinitions.incl name
  for name in source.availableNames:
    result.availableNames.incl name
  for name in source.qualifiedNames:
    result.qualifiedNames.incl name
  for item in source.imports:
    var copied = item
    copied.imported = initHashSet[string]()
    copied.excluded = initHashSet[string]()
    copied.importedSymbols = @[]
    for name in item.imported:
      copied.imported.incl name
    for name in item.excluded:
      copied.excluded.incl name
    for symbol in item.importedSymbols:
      copied.importedSymbols.add symbol
    result.imports.add copied
