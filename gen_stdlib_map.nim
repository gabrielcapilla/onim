import std/[algorithm, json, os, osproc, sequtils, strutils, tables]

type GeneratorConfig = object
  libPath: string
  outputPath: string

proc commandOutput(
    executable, workingDir: string, args: openArray[string]
): tuple[output: string, exitCode: int] =
  var command = quoteShell(executable)
  for argument in args:
    command.add " " & quoteShell(argument)
  try:
    execCmdEx(command, options = {poStdErrToStdOut, poUsePath}, workingDir = workingDir)
  except CatchableError:
    ("", -1)

proc jsonFromOutput(output: string): JsonNode =
  let first = output.find('{')
  let last = output.rfind('}')
  if first < 0 or last <= first:
    return nil
  try:
    parseJson(output[first .. last])
  except CatchableError:
    nil

proc discoverNimConfig(): tuple[nimExe, libPath, nimVersion: string] =
  let nimExe = findExe("nim")
  if nimExe.len == 0:
    return
  var probe = getCurrentDir() / "gen_stdlib_map.nim"
  if not fileExists(probe):
    probe = getAppDir() / "gen_stdlib_map.nim"
  if not fileExists(probe):
    return (nimExe, "", "")
  let dump = commandOutput(
    nimExe,
    getCurrentDir(),
    ["dump", "--dump.format:json", "--hints:off", "--warnings:off", probe],
  ).output
  let root = jsonFromOutput(dump)
  if root == nil or root.kind != JObject:
    return (nimExe, "", "")
  result.nimExe = nimExe
  if root.hasKey("libpath") and root["libpath"].kind == JString:
    result.libPath = root["libpath"].getStr
  if root.hasKey("version") and root["version"].kind == JString:
    result.nimVersion = root["version"].getStr

proc parseConfig(): GeneratorConfig =
  let discovered = discoverNimConfig()
  result.libPath = discovered.libPath
  result.outputPath = getCurrentDir() / "stdlib_map.json"
  for argument in commandLineParams():
    if argument.startsWith("--lib:"):
      result.libPath = argument[6 .. ^1]
    elif argument.startsWith("--output:"):
      result.outputPath = argument[9 .. ^1]
    elif argument.startsWith("-"):
      quit "usage: gen_stdlib_map [--lib:path] [--output:path]"

proc collectNimFiles(directory: string, files: var seq[string]) =
  if not dirExists(directory):
    return
  for kind, path in walkDir(directory, relative = false):
    let name = lastPathPart(path)
    if kind == pcDir:
      if name != "htmldocs" and name != "nimcache" and name != ".git":
        collectNimFiles(path, files)
    elif kind == pcFile and path.toLowerAscii.endsWith(".nim"):
      files.add path

proc moduleName(libPath, filePath: string): string =
  let relative = relativePath(filePath, libPath).replace('\\', '/')
  let withoutExtension = relative.changeFileExt("")
  if withoutExtension.startsWith("std/"):
    return withoutExtension
  let base = lastPathPart(withoutExtension)
  let directory = splitFile(withoutExtension).dir
  if directory.endsWith("/private") or directory == "private":
    return "std/private/" & base
  "std/" & base

proc documentation(nimExe, filePath: string): JsonNode =
  let common = [
    "--stdout:on", "--noImportdoc:on", "--docInternal", "--hints:off", "--warnings:off",
    "--verbosity:0", filePath,
  ]
  # Nim 2.4+ may provide the requested `nim doc --json` spelling. Nim 2.0-
  # 2.2 expose the same compiler doc generator as the `jsondoc` command.
  var args = @["doc", "--json"]
  for argument in common:
    args.add argument
  var output = commandOutput(nimExe, splitFile(filePath).dir, args).output
  result = jsonFromOutput(output)
  if result != nil:
    return
  args = @["jsondoc"]
  for argument in common:
    args.add argument
  output = commandOutput(nimExe, splitFile(filePath).dir, args).output
  return jsonFromOutput(output)

proc entryArity(entry: JsonNode): int =
  if entry != nil and entry.kind == JObject and entry.hasKey("signature") and
      entry["signature"].kind == JObject and entry["signature"].hasKey("arguments") and
      entry["signature"]["arguments"].kind == JArray:
    return entry["signature"]["arguments"].len
  -1

proc entrySignature(entry: JsonNode): string =
  if entry != nil and entry.kind == JObject and entry.hasKey("code") and
      entry["code"].kind == JString:
    return entry["code"].getStr
  ""

proc addReexportAlias(
    symbols: var Table[string, seq[JsonNode]], name, targetModule: string
) =
  if not symbols.hasKey(name):
    return
  var additions: seq[JsonNode] = @[]
  for entry in symbols[name]:
    if entry.kind != JObject:
      continue
    var item = newJObject()
    for key in entry.keys:
      item[key] = entry[key]
    item["module"] = %targetModule
    var duplicate = false
    for existing in symbols[name]:
      if existing.hasKey("module") and existing["module"].getStr == targetModule and
          existing["signature"].getStr == item["signature"].getStr:
        duplicate = true
        break
    if not duplicate:
      additions.add item
  for item in additions:
    symbols[name].add item

proc generate(config: GeneratorConfig, nimVersion: string) =
  if config.libPath.len == 0 or not dirExists(config.libPath):
    quit "cannot locate Nim library; pass --lib:/path/to/nim/lib"
  let nimExe = findExe("nim")
  if nimExe.len == 0:
    quit "cannot find nim in PATH"
  var files: seq[string] = @[]
  collectNimFiles(config.libPath, files)
  files.sort

  var modules = initTable[string, bool]()
  var symbols = initTable[string, seq[JsonNode]]()
  var documented = 0
  for filePath in files:
    let module = moduleName(config.libPath, filePath)
    modules[module] = true
    let docs = documentation(nimExe, filePath)
    if docs == nil or docs.kind != JObject or not docs.hasKey("entries") or
        docs["entries"].kind != JArray:
      continue
    inc documented
    for entry in docs["entries"].items:
      if entry.kind != JObject or not entry.hasKey("name") or
          entry["name"].kind != JString:
        continue
      let name = entry["name"].getStr
      var item = newJObject()
      item["module"] = %module
      item["name"] = %name
      item["kind"] =
        if entry.hasKey("type"):
          entry["type"]
        else:
          %""
      item["arity"] = %entryArity(entry)
      item["signature"] = %entrySignature(entry)
      symbols.mgetOrPut(name, @[]).add item

  # os re-exports its directory iterator implementation. The JSON doc backend
  # records the declaration's implementation module, so retain the public
  # std/os spelling as an additional canonical candidate.
  addReexportAlias(symbols, "walkDir", "std/os")
  addReexportAlias(symbols, "walkDirRec", "std/os")

  var root = newJObject()
  root["generator"] = %"gen_stdlib_map.nim"
  root["nimVersion"] = %nimVersion
  root["modules"] = newJObject()
  var moduleNames = toSeq(modules.keys)
  moduleNames.sort
  for module in moduleNames:
    root["modules"][module] = %true

  root["symbols"] = newJObject()
  var symbolNames = toSeq(symbols.keys)
  symbolNames.sort
  for name in symbolNames:
    var entries = symbols[name]
    entries.sort(
      proc(left, right: JsonNode): int =
        let moduleOrder = cmp(left["module"].getStr, right["module"].getStr)
        if moduleOrder != 0:
          moduleOrder
        else:
          cmp(left["signature"].getStr, right["signature"].getStr)
    )
    var list = newJArray()
    for entry in entries:
      list.add entry
    root["symbols"][name] = list

  writeFile(config.outputPath, pretty(root) & "\n")
  echo "documented ",
    documented, "/", files.len, " modules; wrote ", config.outputPath, " (",
    symbols.len, " symbol names)"

when isMainModule:
  let config = parseConfig()
  let discovered = discoverNimConfig()
  generate(config, discovered.nimVersion)
