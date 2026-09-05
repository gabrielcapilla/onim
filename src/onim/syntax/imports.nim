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

proc moduleText(tokens: seq[Token], first, last: int): string =
  for index in first ..< last:
    if tokens[index].text == ".":
      result.add '/'
    else:
      result.add tokens[index].text

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

proc keepImport(source: string, tokens: seq[Token], start, finish: int): bool =
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

proc statementEnd*[T](tokens: T, start: int): int =
  var index = start + 1
  var nesting = 0
  while index < tokens.len:
    let text = tokens[index].text
    if text == "[" or text == "(" or text == "{":
      inc nesting
    elif text == "]" or text == ")" or text == "}":
      if nesting > 0:
        dec nesting
    elif text == ";" and nesting == 0:
      break
    elif nesting == 0 and tokens[index].line > tokens[start].line:
      let previous =
        if index > start:
          tokens[index - 1].text
        else:
          ""
      if previous != "," and previous != "/" and previous != "." and previous != "\\":
        break
    inc index
  index

proc addFromImportedName(
    info: var ImportInfo, tokens: seq[Token], cursor: var int, finish: int
) =
  while cursor < finish and
      (tokens[cursor].kind != tkIdentifier or tokens[cursor].isKeyword(kwAs)):
    inc cursor
  if cursor >= finish or tokens[cursor].isKeyword(kwExcept):
    return
  let start = tokens[cursor].startOffset
  var name = tokens[cursor].text
  var finishOffset = tokens[cursor].endOffset
  inc cursor
  if cursor < finish and tokens[cursor].isKeyword(kwAs):
    inc cursor
    if cursor < finish and tokens[cursor].kind == tkIdentifier:
      name = tokens[cursor].text
      finishOffset = tokens[cursor].endOffset
      inc cursor
  info.imported.incl name
  info.importedSymbols.add ImportSymbol(
    name: name, startOffset: start, endOffset: finishOffset
  )

proc parseImport(
    tokens: seq[Token], source: string, index: int
): tuple[items: seq[ImportInfo], next: int] =
  let endIndex = statementEnd(tokens, index)
  let keep = keepImport(source, tokens, index, endIndex)
  var cursor = index + 1
  var prefix = ""
  while cursor < endIndex and tokens[cursor].text != "[" and
      not tokens[cursor].isKeyword(kwAs) and not tokens[cursor].isKeyword(kwExcept) and
      tokens[cursor].text != ","
  :
    prefix.add tokens[cursor].text
    inc cursor
  prefix = prefix.strip(chars = {' ', '\t'})
  if cursor < endIndex and tokens[cursor].text == "[":
    inc cursor
    while cursor < endIndex and tokens[cursor].text != "]":
      if tokens[cursor].kind == tkIdentifier:
        var module = prefix
        if module.len > 0 and not module.endsWith("/"):
          module.add '/'
        module.add tokens[cursor].text
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
      if tokens[cursor].text == "," or tokens[cursor].isKeyword(kwAs):
        inc cursor
        continue
      let moduleStart = cursor
      while cursor < endIndex and tokens[cursor].text != "," and
          not tokens[cursor].isKeyword(kwAs) and not tokens[cursor].isKeyword(kwExcept):
        inc cursor
      let module = moduleText(tokens, moduleStart, cursor)
      if module.len == 0:
        continue
      let separatorStart =
        if result.items.len > 0 and moduleStart > 0 and
            tokens[moduleStart - 1].text == ",":
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
          item.alias = tokens[cursor].text
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
        result.items[^1].excluded.incl tokens[cursorExcept].text
      inc cursorExcept
    result.items[^1].itemEndOffset = tokens[endIndex - 1].endOffset
  result.next = endIndex

proc parseFrom(
    tokens: seq[Token], source: string, index: int
): tuple[item: ImportInfo, next: int, valid: bool] =
  let endIndex = statementEnd(tokens, index)
  var importIndex = index + 1
  while importIndex < endIndex and not tokens[importIndex].isKeyword(kwImport):
    inc importIndex
  if importIndex >= endIndex:
    result.next = endIndex
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
    while cursor < endIndex and tokens[cursor].text != "," and
        not tokens[cursor].isKeyword(kwExcept):
      inc cursor
    if cursor < endIndex and tokens[cursor].text == ",":
      inc cursor
  result.item = info
  result.next = endIndex
  result.valid = info.module.len > 0

proc collectDefinitions(tokens: seq[Token]): HashSet[string] =
  result = initHashSet[string]()
  for index, token in tokens:
    if token.kind != tkIdentifier:
      continue
    if token.hasKeywordRole(roleRoutine):
      var cursor = index + 1
      if cursor < tokens.len and tokens[cursor].text == "*":
        inc cursor
      if cursor < tokens.len and tokens[cursor].kind == tkIdentifier:
        result.incl tokens[cursor].text
    elif token.hasKeywordRole(roleTypeDeclaration):
      var cursor = index + 1
      let declarationLine =
        if cursor < tokens.len:
          tokens[cursor].line
        else:
          token.line
      while cursor < tokens.len and tokens[cursor].line == declarationLine and
          tokens[cursor].text != "=" and tokens[cursor].text != ";":
        if tokens[cursor].kind == tkIdentifier:
          result.incl tokens[cursor].text
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
          tokens[cursor].text != ":" and tokens[cursor].text != "=" and
          tokens[cursor].text != ";"
      :
        if tokens[cursor].kind == tkIdentifier:
          result.incl tokens[cursor].text
        inc cursor
    elif token.hasKeywordRole(roleForBinding):
      var cursor = index + 1
      while cursor < tokens.len and tokens[cursor].text != "in" and
          tokens[cursor].text != "=" and tokens[cursor].text != ":":
        if tokens[cursor].kind == tkIdentifier:
          result.incl tokens[cursor].text
        inc cursor
    elif token.hasKeywordRole(roleBindDeclaration):
      var cursor = index + 1
      if cursor < tokens.len and tokens[cursor].kind == tkIdentifier:
        result.incl tokens[cursor].text

proc parseSourceImports*(source: string): SourceImports =
  var tokens = lex(source)
  let lines = source.splitLines
  result.localDefinitions = collectDefinitions(tokens)
  result.availableNames = initHashSet[string]()
  result.qualifiedNames = initHashSet[string]()
  var index = 0
  while index < tokens.len:
    if tokens[index].isKeyword(kwImport):
      let parsed = parseImport(tokens, source, index)
      for parsedItem in parsed.items:
        var item = parsedItem
        item.conditional = conditionalImport(lines, tokens[index])
        result.imports.add item
        if item.conditional:
          continue
        if item.alias.len > 0:
          result.qualifiedNames.incl item.alias
        else:
          result.qualifiedNames.incl moduleText(@[Token(text: item.module)], 0, 1)
          for excluded in item.excluded:
            discard excluded
      index = max(index + 1, parsed.next)
    elif tokens[index].isKeyword(kwFrom):
      let parsed = parseFrom(tokens, source, index)
      if parsed.valid:
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
  result.tokens = initTokenStore(tokens)

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
  if qualifier in imports.qualifiedNames:
    return true
  for item in imports.imports:
    if item.form == importModule and not item.conditional and item.alias.len == 0:
      if moduleLeaf(item.module) == qualifier:
        return true
  false
