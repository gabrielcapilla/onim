import std/[os, osproc, strutils, tables]

when defined(onimEmbedded):
  import nimsuggest/nimsuggest

type CompilerDiagnostic* = object
  name*: string
  file*: string
  line*: int
  column*: int
  message*: string

const maxDiagnosticCacheEntries = 16

var diagnosticCache = initTable[string, seq[CompilerDiagnostic]]()
var diagnosticCacheOrder: seq[string] = @[]

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

proc parseLocation(message: string): tuple[file: string, line: int, column: int] =
  result.line = 0
  result.column = 0
  let open = message.rfind('(')
  let comma =
    if open >= 0:
      message.find(',', open + 1)
    else:
      -1
  let close =
    if comma >= 0:
      message.find(')', comma + 1)
    else:
      -1
  if open < 0 or comma < 0 or close < 0:
    return
  try:
    result.line = parseInt(message[open + 1 ..< comma]) - 1
    result.column = parseInt(message[comma + 1 ..< close]) - 1
    result.file = message[0 ..< open]
  except ValueError:
    discard

proc parseCompilerOutput(output: string): seq[CompilerDiagnostic] =
  for line in output.splitLines:
    let name = extractUndeclaredName(line)
    if name.len == 0:
      continue
    let location = parseLocation(line)
    result.add CompilerDiagnostic(
      name: name,
      file: location.file,
      line: location.line,
      column: location.column,
      message: line,
    )

proc parseSuggestOutput(output: string): seq[CompilerDiagnostic] =
  for line in output.splitLines:
    let name = extractUndeclaredName(line)
    if name.len == 0:
      continue
    let fields = line.split('\t')
    var file = ""
    var lineNumber = 0
    var column = 0
    if fields.len >= 8 and fields[0] == "chk":
      file = fields[4]
      try:
        lineNumber = parseInt(fields[5]) - 1
        column = parseInt(fields[6])
      except ValueError:
        discard
    result.add CompilerDiagnostic(
      name: name, file: file, line: lineNumber, column: column, message: line
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
  let command = ["check", "--hints:off", "--warnings:off", "--errorMax:1000", filePath]
  let output = commandWithArgs(executable, workingDir, command).output
  parseCompilerOutput(output)

proc nimsuggestDiagnostics*(filePath: string): seq[CompilerDiagnostic] =
  let executable = findExe("nimsuggest")
  if executable.len == 0:
    return
  let workingDir = splitFile(filePath).dir
  let command =
    quoteShell(executable) & " --stdin --v4 --hints:off --warnings:off " &
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
      if suggestion.section == ideChk and suggestion.forth == "Error" and
          suggestion.doc.startsWith("undeclared identifier"):
        result.add CompilerDiagnostic(
          name: extractUndeclaredName(suggestion.doc),
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

proc diagnosticCacheKey(filePath, dirtyPath, source: string): string =
  let project = absolutePath(if filePath.len > 0: filePath else: dirtyPath)
  let target = absolutePath(if dirtyPath.len > 0: dirtyPath else: filePath)
  project & "\n" & target & "\n" & source

proc rememberDiagnostics(key: string, diagnostics: seq[CompilerDiagnostic]) =
  if key.len == 0:
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
  let cacheable = not source.contains("include")
  let key =
    if cacheable:
      diagnosticCacheKey(filePath, dirtyPath, source)
    else:
      ""
  if key.len > 0 and diagnosticCache.hasKey(key):
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
