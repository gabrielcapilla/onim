import std/[sets, strutils]

import ./lexer

export lexer

type
  ImportForm* = enum
    importModule
    fromModule

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

  SourceImports* = object
    tokens*: TokenStore
    imports*: seq[ImportInfo]
    localDefinitions*: HashSet[string]
    availableNames*: HashSet[string]
    qualifiedNames*: HashSet[string]

  StatementUncertainty* = enum
    statementIncomplete
    statementUnbalanced
    statementUnsupported

  StatementRange* = object
    past*: int
    uncertainty*: set[StatementUncertainty]

proc moduleText(tokens: TokenStore, first, last: int): string =
  for index in first ..< last:
    if tokens.tokenTextEquals(tokens[index], "."):
      result.add '/'
    else:
      result.add tokens.tokenText(tokens[index])

proc canonicalReference*(module: string): string =
  result = module.strip(chars = {'"', '\'', '`'})
  result = result.replace('\\', '/')
  var prefix = ""
  if result.len > 3 and result.startsWith("../"):
    prefix = "../"
    result = result[3 .. ^1]
  elif result.len > 2 and result.startsWith("./"):
    prefix = "./"
    result = result[2 .. ^1]
  result = result.replace('.', '/')
  while result.contains("//"):
    result = result.replace("//", "/")
  result = prefix & result

proc moduleLeaf*(module: string): string =
  var normalized = module.strip(chars = {'"', '\'', '`'}).replace('\\', '/')
  normalized = normalized.replace('.', '/')
  let slash = normalized.rfind('/')
  if slash >= 0 and slash + 1 < normalized.len:
    normalized = normalized[slash + 1 .. ^1]
  if normalized.toLowerAscii.endsWith(".nim"):
    normalized.setLen(normalized.len - 4)
  normalized

proc lineIndent(source: string, offset: int): string =
  var start = offset
  while start > 0 and source[start - 1] != '\n':
    dec start
  while start < offset and source[start] in {' ', '\t'}:
    result.add source[start]
    inc start

proc keepImport(source: string, tokens: TokenStore, start, finish: int): bool =
  if start < 0 or start >= tokens.len or finish <= start or finish > tokens.len:
    return false
  var lineStart = tokens[start].startOffset
  while lineStart > 0 and source[lineStart - 1] != '\n':
    dec lineStart
  var lineEnd = tokens[start].endOffset
  while lineEnd < source.len and source[lineEnd] != '\n':
    inc lineEnd
  let line = source[lineStart ..< lineEnd].toLowerAscii
  if line.contains("# onim: keep") or line.contains("// onim: keep"):
    return true
  var statement = source[tokens[start].startOffset ..< tokens[finish - 1].endOffset]
  statement = statement.replace(" ", "").replace("\t", "").replace("\r", "")
  statement.contains("{.all.}")

proc conditionalImport(lines: openArray[string], token: Token): bool =
  if token.line <= 0:
    return false
  var line = token.line - 1
  while line >= 0:
    let text = lines[line].strip
    if text.len == 0 or text.startsWith("#"):
      dec line
      continue
    var indent = 0
    while indent < lines[line].len and lines[line][indent] in {' ', '\t'}:
      inc indent
    if indent < token.column:
      return
        text.startsWith("when ") or text.startsWith("elif ") or text == "else:" or
        text.startsWith("else:")
    if indent <= token.column:
      return false
    dec line
  false

proc isModuleStatementStart*(token: Token): bool {.inline.} =
  token.hasKeywordRole(roleImport) or token.hasKeywordRole(roleFrom) or
    token.hasKeywordRole(roleInclude) or token.hasKeywordRole(roleExport)

proc statementRange*(tokens: TokenStore, start: int): StatementRange =
  result.past = min(tokens.len, start + 1)
  if start < 0 or start >= tokens.len:
    return
  var index = start + 1
  var delimiters: seq[char] = @[]
  while index < tokens.len:
    if delimiters.len > 0 and tokens[index].line > tokens[start].line and
        tokens[index].column <= tokens[start].column and
        tokens[index].isModuleStatementStart:
      result.uncertainty.incl statementIncomplete
      result.past = index
      return

    let value =
      if tokens.tokenTextLen(tokens[index]) == 1:
        tokens.tokenTextChar(tokens[index], 0)
      else:
        '\0'
    if isOpeningDelimiter(value):
      delimiters.add value
    elif isClosingDelimiter(value):
      if delimiters.len == 0 or not matchingDelimiter(delimiters[^1], value):
        result.uncertainty.incl statementUnbalanced
      else:
        delimiters.setLen(delimiters.len - 1)
    elif tokens.tokenTextEquals(tokens[index], ";") and delimiters.len == 0:
      result.past = index
      return
    elif delimiters.len == 0 and tokens[index].line > tokens[start].line:
      if index == start + 1 or (
        not tokens.tokenTextEquals(tokens[index - 1], ",") and
        not tokens.tokenTextEquals(tokens[index - 1], "/") and
        not tokens.tokenTextEquals(tokens[index - 1], ".") and
        not tokens.tokenTextEquals(tokens[index - 1], "\\")
      ):
        result.past = index
        return
    inc index
  result.past = index
  if delimiters.len > 0:
    result.uncertainty.incl statementIncomplete

proc statementHasMissingOperand*(tokens: TokenStore, start, past: int): bool =
  if start < 0 or past <= start + 1 or past > tokens.len:
    return true
  let last = tokens[past - 1]
  if last.isKeyword(kwAs) or last.isKeyword(kwExcept) or last.isKeyword(kwImport):
    return true
  if tokens.tokenTextLen(last) != 1:
    return false
  tokens.tokenTextChar(last, 0) in {',', '/', '.', '\\', '[', '(', '{'}

proc fromStatementComplete*(tokens: TokenStore, start, past: int): bool =
  var importIndex = start + 1
  while importIndex < past and not tokens[importIndex].isKeyword(kwImport):
    inc importIndex
  importIndex > start + 1 and importIndex < past and
    not statementHasMissingOperand(tokens, start, past) and
    moduleText(tokens, start + 1, importIndex).len > 0

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

proc includeSegment(tokens: TokenStore, index: int): bool {.inline.} =
  if index < 0 or index >= tokens.len:
    return false
  let token = tokens[index]
  (token.kind == tkIdentifier and token.validIdentifier) or
    (token.kind == tkString and token.isClosedString)

proc includeSeparator(tokens: TokenStore, index: int): bool {.inline.} =
  index >= 0 and index < tokens.len and (
    tokens.tokenTextEquals(tokens[index], "/") or
    tokens.tokenTextEquals(tokens[index], ".") or
    tokens.tokenTextEquals(tokens[index], "\\")
  )

proc parseIncludePath(
    tokens: TokenStore, cursor: var int, finish: int
): tuple[path: string, firstToken, pastToken: int, valid: bool] =
  result.firstToken = cursor
  if not includeSegment(tokens, cursor):
    return
  result.path = tokens.tokenText(tokens[cursor])
  inc cursor
  while cursor < finish and includeSeparator(tokens, cursor):
    result.path.add tokens.tokenText(tokens[cursor])
    inc cursor
    if not includeSegment(tokens, cursor):
      return
    result.path.add tokens.tokenText(tokens[cursor])
    inc cursor
  result.pastToken = cursor
  result.valid = true

proc includeInfo(
    tokens: TokenStore,
    source: string,
    lines: openArray[string],
    statementStart, statementPast, firstToken, pastToken: int,
    module: string,
): ImportInfo =
  if statementStart < 0 or statementPast <= statementStart or statementPast > tokens.len or
      firstToken < 0 or pastToken <= firstToken or pastToken > tokens.len:
    return
  result.form = importModule
  result.module = canonicalReference(module)
  result.startOffset = tokens[statementStart].startOffset
  result.endOffset = tokens[statementPast - 1].endOffset
  result.moduleStartOffset = tokens[firstToken].startOffset
  result.moduleEndOffset = tokens[pastToken - 1].endOffset
  result.diagnosticNameStartOffset = result.moduleStartOffset
  result.diagnosticNameEndOffset = result.moduleEndOffset
  result.itemStartOffset = result.moduleStartOffset
  result.itemEndOffset = result.moduleEndOffset
  result.line = tokens[statementStart].line
  result.indent = lineIndent(source, tokens[statementStart].startOffset)
  if lines.len > 0:
    result.conditional = conditionalImport(lines, tokens[statementStart])

proc parseIncludeItem(
    tokens: TokenStore,
    source: string,
    lines: openArray[string],
    statementStart, statementPast: int,
    cursor: var int,
    finish: int,
): tuple[references: seq[ImportInfo], valid: bool] =
  if not includeSegment(tokens, cursor):
    return
  let firstToken = cursor
  var prefix = tokens.tokenText(tokens[cursor])
  inc cursor
  while cursor < finish and includeSeparator(tokens, cursor):
    let separator = tokens.tokenText(tokens[cursor])
    inc cursor
    if cursor < finish and tokens.tokenTextEquals(tokens[cursor], "[") and
        separator == "/":
      prefix.add separator
      inc cursor
      var groupCount = 0
      while cursor < finish:
        if not includeSegment(tokens, cursor):
          result.valid = false
          return
        let suffix = parseIncludePath(tokens, cursor, finish)
        if not suffix.valid:
          return
        result.references.add includeInfo(
          tokens,
          source,
          lines,
          statementStart,
          statementPast,
          suffix.firstToken,
          suffix.pastToken,
          prefix & suffix.path,
        )
        inc groupCount
        if cursor >= finish:
          return
        if tokens.tokenTextEquals(tokens[cursor], ","):
          inc cursor
          if cursor >= finish or tokens.tokenTextEquals(tokens[cursor], "]"):
            return
        elif tokens.tokenTextEquals(tokens[cursor], "]"):
          inc cursor
          result.valid = groupCount > 0
          return
        else:
          return
      return
    if not includeSegment(tokens, cursor):
      return
    prefix.add separator
    prefix.add tokens.tokenText(tokens[cursor])
    inc cursor
  result.references.add includeInfo(
    tokens, source, lines, statementStart, statementPast, firstToken, cursor, prefix
  )
  result.valid = true

proc parseIncludeReferences*(
    tokens: TokenStore, source: string, index: int
): tuple[references: seq[ImportInfo], next: int, uncertainty: set[StatementUncertainty]] =
  let statement = statementRange(tokens, index)
  let endIndex = statement.past
  let lines = source.splitLines
  result.next = endIndex
  result.uncertainty = statement.uncertainty
  if statementHasMissingOperand(tokens, index, endIndex):
    result.uncertainty.incl statementIncomplete
    return
  var cursor = index + 1
  while cursor < endIndex:
    let item =
      parseIncludeItem(tokens, source, lines, index, endIndex, cursor, endIndex)
    if not item.valid:
      result.references.setLen(0)
      result.uncertainty.incl statementUnsupported
      return
    for reference in item.references:
      if reference.module.len == 0:
        result.references.setLen(0)
        result.uncertainty.incl statementUnsupported
        return
      result.references.add reference
    if cursor >= endIndex:
      break
    if not tokens.tokenTextEquals(tokens[cursor], ","):
      result.references.setLen(0)
      result.uncertainty.incl statementUnsupported
      return
    inc cursor
    if cursor >= endIndex:
      result.references.setLen(0)
      result.uncertainty.incl statementIncomplete
      return
  if result.references.len == 0:
    result.uncertainty.incl statementIncomplete

proc exportNameToken(tokens: TokenStore, index: int): bool {.inline.} =
  index >= 0 and index < tokens.len and tokens[index].kind == tkIdentifier and
    tokens[index].validIdentifier and not tokens[index].isStropped and
    not tokens[index].isNimKeyword

proc parseExportNames*(
    tokens: TokenStore, index: int
): tuple[names: seq[string], next: int, uncertainty: set[StatementUncertainty]] =
  let statement = statementRange(tokens, index)
  let endIndex = statement.past
  result.next = endIndex
  result.uncertainty = statement.uncertainty
  if statementHasMissingOperand(tokens, index, endIndex):
    result.uncertainty.incl statementIncomplete
    return
  var cursor = index + 1
  while cursor < endIndex:
    if not exportNameToken(tokens, cursor):
      result.names.setLen(0)
      result.uncertainty.incl statementUnsupported
      return
    result.names.add tokens.tokenText(tokens[cursor])
    inc cursor
    if cursor >= endIndex:
      break
    if not tokens.tokenTextEquals(tokens[cursor], ","):
      result.names.setLen(0)
      result.uncertainty.incl statementUnsupported
      return
    inc cursor
    if cursor >= endIndex:
      result.names.setLen(0)
      result.uncertainty.incl statementIncomplete
      return

proc collectDefinitions(tokens: TokenStore): HashSet[string] =
  result = initHashSet[string]()
  for index, token in tokens:
    if token.kind != tkIdentifier:
      continue
    if token.hasKeywordRole(roleRoutine):
      var cursor = index + 1
      if cursor < tokens.len and tokens.tokenTextEquals(tokens[cursor], "*"):
        inc cursor
      if cursor < tokens.len and tokens[cursor].kind == tkIdentifier:
        result.incl tokens.tokenText(tokens[cursor])
    elif token.hasKeywordRole(roleTypeDeclaration):
      var cursor = index + 1
      let declarationLine =
        if cursor < tokens.len:
          tokens[cursor].line
        else:
          token.line
      while cursor < tokens.len and tokens[cursor].line == declarationLine and
          not tokens.tokenTextEquals(tokens[cursor], "=") and
          not tokens.tokenTextEquals(tokens[cursor], ";")
      :
        if tokens[cursor].kind == tkIdentifier:
          result.incl tokens.tokenText(tokens[cursor])
          break
        inc cursor
    elif token.hasKeywordRole(roleValueDeclaration):
      var cursor = index + 1
      let declarationLine =
        if cursor < tokens.len:
          tokens[cursor].line
        else:
          token.line
      while cursor < tokens.len and tokens[cursor].line == declarationLine and
          not tokens.tokenTextEquals(tokens[cursor], ":") and
          not tokens.tokenTextEquals(tokens[cursor], "=") and
          not tokens.tokenTextEquals(tokens[cursor], ";")
      :
        if tokens[cursor].kind == tkIdentifier:
          result.incl tokens.tokenText(tokens[cursor])
        inc cursor
    elif token.hasKeywordRole(roleForBinding):
      var cursor = index + 1
      while cursor < tokens.len and not tokens.tokenTextEquals(tokens[cursor], "in") and
          not tokens.tokenTextEquals(tokens[cursor], "=") and
          not tokens.tokenTextEquals(tokens[cursor], ":")
      :
        if tokens[cursor].kind == tkIdentifier:
          result.incl tokens.tokenText(tokens[cursor])
        inc cursor
    elif token.hasKeywordRole(roleBindDeclaration):
      var cursor = index + 1
      if cursor < tokens.len and tokens[cursor].kind == tkIdentifier:
        result.incl tokens.tokenText(tokens[cursor])

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
          if item.conditional:
            continue
          if item.alias.len > 0:
            result.qualifiedNames.incl item.alias
          else:
            result.qualifiedNames.incl moduleLeaf(item.module)
            for excluded in item.excluded:
              discard excluded
      index = max(index + 1, parsed.next)
    elif tokens[index].isKeyword(kwFrom):
      let parsed = parseFrom(tokens, source, index)
      if parsed.valid and parsed.uncertainty == {}:
        var item = parsed.item
        item.conditional = conditionalImport(lines, tokens[index])
        result.imports.add item
        if not item.conditional:
          for name in item.imported:
            result.availableNames.incl name
      index = max(index + 1, parsed.next)
    else:
      inc index
  for name in result.localDefinitions:
    result.availableNames.incl name
  result.tokens = tokens

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

proc tokenInsideImport*(imports: SourceImports, token: Token): bool =
  for item in imports.imports:
    if not item.synthetic and token.startOffset >= item.startOffset and
        token.endOffset <= item.endOffset:
      return true

proc hasModuleImport*(imports: SourceImports, module: string): bool =
  for item in imports.imports:
    if item.form == importModule and not item.conditional and item.alias.len == 0 and
        item.excluded.len == 0 and (
      item.module == module or item.module.endsWith('/' & module) or
      (module.startsWith("std/") and item.module == module[4 .. ^1])
    ):
      return true

proc providesName*(imports: SourceImports, name: string): bool =
  if name in imports.localDefinitions:
    return true
  name in imports.availableNames

proc providesQualifier*(imports: SourceImports, qualifier: string): bool =
  for known in imports.qualifiedNames:
    if sameIdentifier(known, qualifier):
      return true
  for item in imports.imports:
    if item.form == importModule and not item.conditional:
      let known =
        if item.alias.len > 0:
          item.alias
        else:
          moduleLeaf(item.module)
      if sameIdentifier(known, qualifier):
        return true
  false
