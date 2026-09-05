import std/[hashes, os, osproc, strutils, tables]

import ../index/source_index

when defined(onimEmbedded):
  import nimsuggest/nimsuggest

type
  CompilerDiagnosticKind* = enum
    diagnosticError
    diagnosticHint
    diagnosticWarning

  DiagnosticNames = object
    unused: string
    unusedDeclaration: string
    undeclared: string

  CompilerDiagnostic* = object
    kind*: CompilerDiagnosticKind
    isUnusedImport*: bool
    isUnusedDeclaration*: bool
    name*: string
    file*: string
    line*: int
    column*: int
    message*: string

  DiagnosticCacheKey = object
    project: string
    target: string
    contentHash: uint64
    byteLength: uint32

const maxDiagnosticCacheEntries = 16

var diagnosticCache = initTable[DiagnosticCacheKey, seq[CompilerDiagnostic]]()
var diagnosticCacheOrder: seq[DiagnosticCacheKey] = @[]

proc extractUndeclaredName(message: string): string =
  let marker = "undeclared identifier"
  let markerPosition = message.find(marker)
  if markerPosition < 0:
    return
  let start = message.find('\'', markerPosition + marker.len)
  if start >= 0:
    let finish = message.find('\'', start + 1)
    if finish > start:
      return message[start + 1 ..< finish]
  let colon = message.find(':', markerPosition + marker.len)
  if colon >= 0:
    return message[colon + 1 .. ^1].strip(chars = {' ', '\t', '\"'})

proc extractUnusedImportName(message: string): string =
  let normalized = message.toLowerAscii
  let markerPosition = normalized.find("[unusedimport]")
  if markerPosition < 0:
    return
  let descriptionPosition = normalized.find("imported and not used")
  if descriptionPosition < 0:
    return
  let colon = message.find(':', descriptionPosition)
  if colon < 0 or colon >= markerPosition:
    return
  for position in colon + 1 ..< markerPosition:
    if message[position] notin {'\'', '"', '`'}:
      continue
    let quote = message[position]
    let finish = message.find(quote, position + 1)
    if finish > position:
      return message[position + 1 ..< finish]
  message[colon + 1 ..< markerPosition].strip

proc extractUnusedDeclarationName(message: string): string =
  let normalized = message.toLowerAscii
  let markerPosition = normalized.find("[xdeclaredbutnotused]")
  if markerPosition < 0 or
      not normalized[0 ..< markerPosition].contains("is declared but not used"):
    return
  let quoteStart = message.find('\'')
  if quoteStart >= 0 and quoteStart < markerPosition:
    let quoteEnd = message.find('\'', quoteStart + 1)
    if quoteEnd > quoteStart and quoteEnd < markerPosition:
      return message[quoteStart + 1 ..< quoteEnd]
  message[0 ..< markerPosition].strip

proc diagnosticNames(message: string): DiagnosticNames =
  result.unused = extractUnusedImportName(message)
  result.unusedDeclaration = extractUnusedDeclarationName(message)
  result.undeclared = extractUndeclaredName(message)

proc diagnosticName(names: DiagnosticNames): string {.inline.} =
  if names.unused.len > 0:
    return names.unused
  if names.unusedDeclaration.len > 0:
    return names.unusedDeclaration
  names.undeclared

proc buildDiagnostic(
    message: string,
    names: DiagnosticNames,
    kind: CompilerDiagnosticKind,
    file: string,
    line, column: int,
): CompilerDiagnostic =
  result = CompilerDiagnostic(
    kind: if names.unused.len > 0: kind else: diagnosticError,
    isUnusedImport: names.unused.len > 0,
    isUnusedDeclaration: names.unusedDeclaration.len > 0,
    name: diagnosticName(names),
    file: file,
    line: line,
    column: column,
    message: message,
  )

proc diagnosticKind(level: string): CompilerDiagnosticKind =
  case level.toLowerAscii
  of "hint": diagnosticHint
  of "warning": diagnosticWarning
  else: diagnosticError

proc lineDiagnosticKind(line: string): CompilerDiagnosticKind =
  let normalized = line.toLowerAscii
  if normalized.contains("warning:"):
    diagnosticWarning
  elif normalized.contains("hint:"):
    diagnosticHint
  else:
    diagnosticError

proc parseLocation(message: string): tuple[file: string, line: int, column: int] =
  result.line = 0
  result.column = 0
  var close = message.len - 1
  while close >= 0:
    if message[close] == ')':
      var comma = close - 1
      while comma >= 0 and message[comma] != ',':
        dec comma
      if comma >= 0:
        var opening = comma - 1
        while opening >= 0 and message[opening] != '(':
          dec opening
        if opening >= 0:
          try:
            let line = parseInt(message[opening + 1 ..< comma].strip) - 1
            let column = parseInt(message[comma + 1 ..< close].strip) - 1
            if line >= 0 and column >= 0:
              result.line = line
              result.column = column
              result.file = message[0 ..< opening]
              return
          except ValueError:
            discard
    dec close

proc parseCompilerOutput(output: string): seq[CompilerDiagnostic] =
  for line in output.splitLines:
    let names = diagnosticNames(line)
    let name = diagnosticName(names)
    if name.len == 0:
      continue
    let location = parseLocation(line)
    result.add buildDiagnostic(
      line,
      names,
      lineDiagnosticKind(line),
      location.file,
      location.line,
      location.column,
    )

proc parseSuggestOutput(output: string): seq[CompilerDiagnostic] =
  for line in output.splitLines:
    let names = diagnosticNames(line)
    let name = diagnosticName(names)
    if name.len == 0:
      continue
    let fields = line.split('\t')
    var file = ""
    var lineNumber = 0
    var column = 0
    var level = "Error"
    if fields.len >= 8 and fields[0] == "chk":
      level = fields[3]
      file = fields[4]
      try:
        lineNumber = parseInt(fields[5]) - 1
        column = parseInt(fields[6])
      except ValueError:
        discard
    result.add buildDiagnostic(
      line, names, diagnosticKind(level), file, lineNumber, column
    )

proc commandWithArgs(
    executable, workingDir: string, args: openArray[string]
): tuple[output: string, exitCode: int] =
  try:
    var command = quoteShell(executable)
    for argument in args:
      command.add " " & quoteShell(argument)
    execCmdEx(command, options = {poStdErrToStdOut, poUsePath}, workingDir = workingDir)
  except CatchableError:
    ("", -1)

proc compilerDiagnostics*(filePath: string): seq[CompilerDiagnostic] =
  let executable = findExe("nim")
  if executable.len == 0:
    return
  let workingDir = splitFile(filePath).dir
  let command = ["check", "--hints:on", "--warnings:on", "--errorMax:1000", filePath]
  let output = commandWithArgs(executable, workingDir, command).output
  parseCompilerOutput(output)

proc nimsuggestDiagnostics*(filePath: string): seq[CompilerDiagnostic] =
  let executable = findExe("nimsuggest")
  if executable.len == 0:
    return
  let workingDir = splitFile(filePath).dir
  let command =
    quoteShell(executable) & " --stdin --v4 --hints:on --warnings:on " &
    quoteShell(filePath)
  let request = "chkfile \"" & filePath.replace("\"", "\\\"") & "\":0:0\nquit\n"
  try:
    let output = execCmdEx(
      command,
      options = {poStdErrToStdOut, poUsePath},
      workingDir = workingDir,
      input = request,
    ).output
    return parseSuggestOutput(output)
  except CatchableError:
    discard

when defined(onimEmbedded):
  var cachedSuggest: NimSuggest
  var cachedProject = ""

  proc nimPrefix(project: string): string =
    let executable = findExe("nim")
    if executable.len == 0:
      return ""
    try:
      let command =
        quoteShell(executable) & " dump --dump.format:json --hints:off --warnings:off " &
        quoteShell(project)
      let output = execCmdEx(
        command,
        options = {poStdErrToStdOut, poUsePath},
        workingDir = splitFile(project).dir,
      ).output
      let marker = "\"prefixdir\":\""
      let start = output.find(marker)
      if start >= 0:
        let first = start + marker.len
        let finish = output.find('"', first)
        if finish > first:
          return output[first ..< finish]
    except CatchableError:
      discard
    ""

  proc embeddedDiagnostics(filePath, dirtyPath: string): seq[CompilerDiagnostic] =
    let project = absolutePath(if filePath.len > 0: filePath else: dirtyPath)
    if cachedSuggest == nil or cachedProject != project:
      cachedSuggest = initNimSuggest(project, nimPrefix(project))
      cachedProject = project
    let dirty = absolutePath(if dirtyPath.len > 0: dirtyPath else: project)
    for suggestion in cachedSuggest.runCmd(
      ideChk, AbsoluteFile(project), AbsoluteFile(dirty), 0, -1
    ):
      let unusedName = extractUnusedImportName(suggestion.doc)
      let unusedDeclarationName = extractUnusedDeclarationName(suggestion.doc)
      let undeclaredName = extractUndeclaredName(suggestion.doc)
      if suggestion.section == ideChk and (
        undeclaredName.len > 0 or unusedName.len > 0 or unusedDeclarationName.len > 0
      ):
        result.add CompilerDiagnostic(
          kind:
            if unusedName.len > 0 or unusedDeclarationName.len > 0:
              diagnosticKind(suggestion.forth)
            else:
              diagnosticError,
          isUnusedImport: unusedName.len > 0,
          isUnusedDeclaration: unusedDeclarationName.len > 0,
          name:
            if unusedName.len > 0:
              unusedName
            elif unusedDeclarationName.len > 0:
              unusedDeclarationName
            else:
              undeclaredName,
          file: suggestion.filePath,
          line: suggestion.line,
          column: suggestion.column,
          message: suggestion.doc,
        )

  proc checkFile*(filePath: string, dirtyPath = ""): seq[CompilerDiagnostic] =
    # Nim 2.x exposes the compiler module graph and semantic passes through
    # nimsuggest's embedded API. The adapter keeps that dependency in one file;
    # all edits still require an Error/undeclared-identifier result from the
    # actual compiler rather than a lexical guess.
    embeddedDiagnostics(filePath, dirtyPath)

else:
  proc checkFile*(filePath: string, dirtyPath = ""): seq[CompilerDiagnostic] =
    # This fallback keeps source builds usable when the host does not ship the
    # compiler sources needed by the embedded nimsuggest API.
    var seen = newSeq[string]()
    for diagnostic in compilerDiagnostics(
      if dirtyPath.len > 0: dirtyPath else: filePath
    ) & nimsuggestDiagnostics(if dirtyPath.len > 0: dirtyPath else: filePath):
      if diagnostic.name notin seen:
        seen.add diagnostic.name
        result.add diagnostic

proc hash(key: DiagnosticCacheKey): Hash =
  result = hash(key.project)
  result = result !& hash(key.target)
  result = result !& hash(key.contentHash)
  result = result !& hash(key.byteLength)
  result = !$result

proc diagnosticCacheKey(filePath, dirtyPath, source: string): DiagnosticCacheKey =
  result.project = absolutePath(if filePath.len > 0: filePath else: dirtyPath)
  result.target = absolutePath(if dirtyPath.len > 0: dirtyPath else: filePath)
  result.contentHash = contentFingerprint(source)
  result.byteLength = uint32(source.len)

proc rememberDiagnostics(
    key: DiagnosticCacheKey, diagnostics: seq[CompilerDiagnostic]
) =
  if key.project.len == 0 or key.target.len == 0:
    return
  if diagnosticCache.hasKey(key):
    diagnosticCache[key] = diagnostics
    let oldIndex = diagnosticCacheOrder.find(key)
    if oldIndex >= 0:
      diagnosticCacheOrder.delete(oldIndex)
  else:
    diagnosticCache[key] = diagnostics
  diagnosticCacheOrder.add key
  while diagnosticCacheOrder.len > maxDiagnosticCacheEntries:
    let oldest = diagnosticCacheOrder[0]
    diagnosticCacheOrder.delete(0)
    diagnosticCache.del oldest

proc cachedCheckFile*(filePath: string, dirtyPath = ""): seq[CompilerDiagnostic] =
  let target = if dirtyPath.len > 0: dirtyPath else: filePath
  if target.len == 0 or not fileExists(target):
    return
  var source: string
  try:
    source = readFile(target)
  except CatchableError:
    return checkFile(filePath, dirtyPath)

  # Included files are external inputs to the source text. Do not cache those
  # checks unless their dependency graph is fingerprinted as well.
  let cacheable = not source.contains("include") and source.len <= int(high(uint32))
  if not cacheable:
    return checkFile(filePath, dirtyPath)
  let key = diagnosticCacheKey(filePath, dirtyPath, source)
  if diagnosticCache.hasKey(key):
    let cached = diagnosticCache[key]
    let oldIndex = diagnosticCacheOrder.find(key)
    if oldIndex >= 0:
      diagnosticCacheOrder.delete(oldIndex)
      diagnosticCacheOrder.add key
    return cached

  result = checkFile(filePath, dirtyPath)
  if cacheable:
    rememberDiagnostics(key, result)

proc checkFileCached*(filePath: string, dirtyPath = ""): seq[CompilerDiagnostic] =
  cachedCheckFile(filePath, dirtyPath)
