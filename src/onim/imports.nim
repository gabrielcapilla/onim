import std/[sets, strutils]

import ./lexer

type
  ImportForm* = enum
    importModule
    fromModule

  ImportInfo* = object
    form*: ImportForm
    module*: string
    alias*: string
    imported*: HashSet[string]
    excluded*: HashSet[string]
    startOffset*: int
    endOffset*: int
    line*: int
    indent*: string
    synthetic*: bool
    conditional*: bool

  SourceImports* = object
    tokens*: seq[Token]
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

proc lineIndent(source: string, offset: int): string =
  var start = offset
  while start > 0 and source[start - 1] != '\n':
    dec start
  while start < offset and source[start] in {' ', '\t'}:
    result.add source[start]
    inc start

proc conditionalImport(source: string, token: Token): bool =
  if token.line <= 0:
    return false
  let lines = source.splitLines
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

proc statementEnd(tokens: seq[Token], start: int): int =
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

proc addImportedName(info: var ImportInfo, name: string) =
  if name.len > 0 and name != "*":
    info.imported.incl name

proc parseImport(
    tokens: seq[Token], source: string, index: int
): tuple[items: seq[ImportInfo], next: int] =
  let endIndex = statementEnd(tokens, index)
  var cursor = index + 1
  var prefix = ""
  while cursor < endIndex and tokens[cursor].text != "[" and tokens[cursor].text != "as" and
      tokens[cursor].text != "except" and tokens[cursor].text != ",":
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
          startOffset: tokens[index].startOffset,
          endOffset: tokens[endIndex - 1].endOffset,
          line: tokens[index].line,
          indent: lineIndent(source, tokens[index].startOffset),
        )
        result.items.add item
      inc cursor
  else:
    cursor = index + 1
    while cursor < endIndex:
      if tokens[cursor].text == "except":
        break
      if tokens[cursor].text == "," or tokens[cursor].text == "as":
        inc cursor
        continue
      let moduleStart = cursor
      while cursor < endIndex and tokens[cursor].text != "," and
          tokens[cursor].text != "as" and tokens[cursor].text != "except":
        inc cursor
      let module = moduleText(tokens, moduleStart, cursor)
      if module.len == 0:
        continue
      var item = ImportInfo(
        form: importModule,
        module: module,
        imported: initHashSet[string](),
        excluded: initHashSet[string](),
        startOffset: tokens[index].startOffset,
        endOffset: tokens[endIndex - 1].endOffset,
        line: tokens[index].line,
        indent: lineIndent(source, tokens[index].startOffset),
      )
      if cursor < endIndex and tokens[cursor].text == "as":
        inc cursor
        if cursor < endIndex and tokens[cursor].kind == tkIdentifier:
          item.alias = tokens[cursor].text
          inc cursor
      result.items.add item

  # `except` belongs to the module immediately before it, including bracketed
  # imports. It is intentionally kept separate from imported names.
  var exceptIndex = index + 1
  while exceptIndex < endIndex and tokens[exceptIndex].text != "except":
    inc exceptIndex
  if exceptIndex < endIndex and result.items.len > 0:
    var cursorExcept = exceptIndex + 1
    while cursorExcept < endIndex:
      if tokens[cursorExcept].kind == tkIdentifier:
        result.items[^1].excluded.incl tokens[cursorExcept].text
      inc cursorExcept
  result.next = endIndex

proc parseFrom(
    tokens: seq[Token], source: string, index: int
): tuple[item: ImportInfo, next: int, valid: bool] =
  let endIndex = statementEnd(tokens, index)
  var importIndex = index + 1
  while importIndex < endIndex and tokens[importIndex].text != "import":
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
  )
  for cursor in importIndex + 1 ..< endIndex:
    if tokens[cursor].kind == tkIdentifier and tokens[cursor].text != "except" and
        tokens[cursor].text != "as":
      info.addImportedName tokens[cursor].text
  result.item = info
  result.next = endIndex
  result.valid = info.module.len > 0

proc collectDefinitions(tokens: seq[Token]): HashSet[string] =
  result = initHashSet[string]()
  for index, token in tokens:
    if token.kind != tkIdentifier:
      continue
    if token.text == "proc" or token.text == "func" or token.text == "iterator" or
        token.text == "method" or token.text == "macro" or token.text == "template" or
        token.text == "converter":
      var cursor = index + 1
      if cursor < tokens.len and tokens[cursor].text == "*":
        inc cursor
      if cursor < tokens.len and tokens[cursor].kind == tkIdentifier:
        result.incl tokens[cursor].text
    elif token.text == "type":
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
    elif token.text == "var" or token.text == "let" or token.text == "const":
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
    elif token.text == "for":
      var cursor = index + 1
      while cursor < tokens.len and tokens[cursor].text != "in" and
          tokens[cursor].text != "=" and tokens[cursor].text != ":":
        if tokens[cursor].kind == tkIdentifier:
          result.incl tokens[cursor].text
        inc cursor
    elif token.text == "bind":
      var cursor = index + 1
      if cursor < tokens.len and tokens[cursor].kind == tkIdentifier:
        result.incl tokens[cursor].text

proc parseSourceImports*(source: string): SourceImports =
  result.tokens = lex(source)
  result.localDefinitions = collectDefinitions(result.tokens)
  result.availableNames = initHashSet[string]()
  result.qualifiedNames = initHashSet[string]()
  var index = 0
  while index < result.tokens.len:
    if result.tokens[index].text == "import":
      let parsed = parseImport(result.tokens, source, index)
      for parsedItem in parsed.items:
        var item = parsedItem
        item.conditional = conditionalImport(source, result.tokens[index])
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
    elif result.tokens[index].text == "from":
      let parsed = parseFrom(result.tokens, source, index)
      if parsed.valid:
        var item = parsed.item
        item.conditional = conditionalImport(source, result.tokens[index])
        result.imports.add item
        if not item.conditional:
          for name in item.imported:
            result.availableNames.incl name
      index = max(index + 1, parsed.next)
    else:
      inc index
  for name in result.localDefinitions:
    result.availableNames.incl name

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
    for name in item.imported:
      copied.imported.incl name
    for name in item.excluded:
      copied.excluded.incl name
    result.imports.add copied

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
      let slash = item.module.rfind('/')
      let base =
        if slash >= 0:
          item.module[slash + 1 .. ^1]
        else:
          item.module
      if base == qualifier:
        return true
  false
