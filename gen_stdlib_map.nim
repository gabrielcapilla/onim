import std/[algorithm, json, os, osproc, sequtils, strutils, tables]

type GeneratorConfig = object
  libPath: string
  outputPath: string

type CanonicalSymbol = object
  name: string
  module: string

type
  BinaryStringPool = object
    values: seq[string]
    ids: Table[string, uint32]

  BinaryCandidate = object
    module: string
    name: string
    kind: string
    arity: int
    signature: string
    priority: int

  BinarySymbol = object
    name: string
    firstCandidate: uint32
    candidateCount: uint32

const
  stdlibBinaryMagic = "ONIMBIN1"
  stdlibBinaryVersion = 1'u32

proc binaryFingerprint(value: string): uint64 =
  var resultValue = 14695981039346656037'u64
  for character in value:
    resultValue = (resultValue xor uint64(ord(character))) * 1099511628211'u64
  resultValue

proc appendByte(data: var string, value: uint8) =
  data.add char(value)

proc appendUint32(data: var string, value: uint32) =
  for shift in 0 .. 3:
    data.appendByte(uint8((value shr (shift * 8)) and 0xFF'u32))

proc appendInt32(data: var string, value: int32) =
  data.appendUint32(cast[uint32](value))

proc appendUint64(data: var string, value: uint64) =
  for shift in 0 .. 7:
    data.appendByte(uint8((value shr (shift * 8)) and 0xFF'u64))

proc poolId(pool: var BinaryStringPool, value: string): uint32 =
  if pool.ids.hasKey(value):
    return pool.ids[value]
  if pool.values.len >= int(high(uint32)):
    quit "stdlib binary string pool is too large"
  result = uint32(pool.values.len)
  pool.values.add value
  pool.ids[value] = result

proc entryPriority(entry: JsonNode): int =
  if entry != nil and entry.kind == JObject and entry.hasKey("priority") and
      entry["priority"].kind == JInt:
    return entry["priority"].getInt
  0

proc binaryOutputPath(jsonPath: string): string =
  changeFileExt(jsonPath, "bin")

proc entryArity(entry: JsonNode): int

proc writeStdlibBinary(root: JsonNode, outputPath: string) =
  if root == nil or root.kind != JObject or not root.hasKey("modules") or
      root["modules"].kind != JObject or not root.hasKey("symbols") or
      root["symbols"].kind != JObject or not root.hasKey("implicitModules") or
      root["implicitModules"].kind != JArray:
    quit "cannot write binary stdlib map from incomplete JSON"

  var moduleNames: seq[string] = @[]
  var moduleSet = initTable[string, bool]()
  for module in json.keys(root["modules"]):
    moduleSet[module] = true

  var implicitModules: seq[string] = @[]
  for item in root["implicitModules"].items:
    if item.kind != JString:
      quit "stdlib binary implicit module is not a string"
    implicitModules.add item.getStr
  implicitModules.sort

  var symbolNames = toSeq(json.keys(root["symbols"]))
  symbolNames.sort
  var symbols: seq[BinarySymbol] = @[]
  var candidates: seq[BinaryCandidate] = @[]
  for name in symbolNames:
    let entries = root["symbols"][name]
    if entries.kind != JArray:
      quit "stdlib binary symbol entries are not an array"
    var symbol = BinarySymbol(name: name, firstCandidate: uint32(candidates.len))
    for entry in entries.items:
      if entry.kind != JObject or not entry.hasKey("module") or
          entry["module"].kind != JString or not entry.hasKey("kind") or
          entry["kind"].kind != JString:
        quit "stdlib binary candidate is incomplete"
      let priority = entryPriority(entry)
      if priority < 0 or priority > 1:
        quit "stdlib binary candidate priority is invalid"
      let module = entry["module"].getStr
      let exportedName =
        if entry.hasKey("name") and entry["name"].kind == JString:
          entry["name"].getStr
        else:
          name
      let signature =
        if entry.hasKey("signature") and entry["signature"].kind == JString:
          entry["signature"].getStr
        else:
          ""
      candidates.add BinaryCandidate(
        module: module,
        name: if exportedName.len > 0: exportedName else: name,
        kind: entry["kind"].getStr,
        arity: entryArity(entry),
        signature: signature,
        priority: priority,
      )
      moduleSet[module] = true
    symbol.candidateCount = uint32(candidates.len) - symbol.firstCandidate
    symbols.add symbol

  moduleNames = toSeq(tables.keys(moduleSet))
  moduleNames.sort
  var pool = BinaryStringPool(ids: initTable[string, uint32]())
  for module in moduleNames:
    discard pool.poolId(module)
  for module in implicitModules:
    discard pool.poolId(module)
  for symbol in symbols:
    discard pool.poolId(symbol.name)
  for candidate in candidates:
    discard pool.poolId(candidate.module)
    discard pool.poolId(candidate.name)
    discard pool.poolId(candidate.kind)
    discard pool.poolId(candidate.signature)

  var offsets: seq[uint32] = @[]
  var lengths: seq[uint32] = @[]
  var blob = ""
  for value in pool.values:
    if uint64(blob.len) + uint64(value.len) > uint64(high(uint32)):
      quit "stdlib binary string blob is too large"
    offsets.add uint32(blob.len)
    lengths.add uint32(value.len)
    blob.add value

  var payload = ""
  payload.appendUint32(uint32(pool.values.len))
  payload.appendUint32(uint32(moduleNames.len))
  payload.appendUint32(uint32(symbols.len))
  payload.appendUint32(uint32(candidates.len))
  payload.appendUint32(uint32(implicitModules.len))
  payload.appendUint32(uint32(blob.len))
  for index in 0 ..< pool.values.len:
    payload.appendUint32(offsets[index])
    payload.appendUint32(lengths[index])
  payload.add blob
  for module in moduleNames:
    payload.appendUint32(pool.ids[module])
  for module in implicitModules:
    payload.appendUint32(pool.ids[module])
  for symbol in symbols:
    payload.appendUint32(pool.ids[symbol.name])
    payload.appendUint32(symbol.firstCandidate)
    payload.appendUint32(symbol.candidateCount)
  for candidate in candidates:
    payload.appendUint32(pool.ids[candidate.module])
    payload.appendUint32(pool.ids[candidate.name])
    payload.appendUint32(pool.ids[candidate.kind])
    payload.appendInt32(int32(candidate.arity))
    payload.appendUint32(pool.ids[candidate.signature])
    payload.appendByte(uint8(candidate.priority))
    payload.appendByte(0'u8)
    payload.appendByte(0'u8)
    payload.appendByte(0'u8)

  var binary = stdlibBinaryMagic
  binary.appendUint32(stdlibBinaryVersion)
  binary.appendByte(1'u8)
  binary.appendByte(0'u8)
  binary.appendByte(0'u8)
  binary.appendByte(0'u8)
  binary.appendUint64(uint64(payload.len))
  binary.appendUint64(binaryFingerprint(payload))
  binary.add payload
  writeFile(outputPath, binary)

const canonicalSymbols = [
  CanonicalSymbol(name: "walkDir", module: "std/os"),
  CanonicalSymbol(name: "walkDirRec", module: "std/os"),
  CanonicalSymbol(name: "Table", module: "std/tables"),
  CanonicalSymbol(name: "initTable", module: "std/tables"),
  CanonicalSymbol(name: "parseJson", module: "std/json"),
  CanonicalSymbol(name: "split", module: "std/strutils"),
]

proc isCanonicalSymbol(name, module: string): bool =
  for candidate in canonicalSymbols:
    if candidate.name == name and candidate.module == module:
      return true
  false

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
  if entry != nil and entry.kind == JObject and entry.hasKey("arity") and
      entry["arity"].kind == JInt:
    return entry["arity"].getInt
  if entry != nil and entry.kind == JObject and entry.hasKey("signature") and
      entry["signature"].kind == JObject and entry["signature"].hasKey("arguments") and
      entry["signature"]["arguments"].kind == JArray:
    return entry["signature"]["arguments"].len
  -1

proc normalizedSignature(signature, libPath: string): string =
  result = signature
  let normalizedLib = absolutePath(libPath).replace('\\', '/')
  if normalizedLib.len > 0:
    result = result.replace(normalizedLib, "<nimlib>")

proc entrySignature(entry: JsonNode, libPath: string): string =
  if entry != nil and entry.kind == JObject and entry.hasKey("code") and
      entry["code"].kind == JString:
    return normalizedSignature(entry["code"].getStr, libPath)
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
    if isCanonicalSymbol(name, targetModule):
      item["priority"] = %1
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
      if isCanonicalSymbol(name, module):
        item["priority"] = %1
      item["kind"] =
        if entry.hasKey("type"):
          entry["type"]
        else:
          %""
      item["arity"] = %entryArity(entry)
      item["signature"] = %entrySignature(entry, config.libPath)
      symbols.mgetOrPut(name, @[]).add item

  # os re-exports its directory iterator implementation. The JSON doc backend
  # records the declaration's implementation module, so retain the public
  # std/os spelling as an additional canonical candidate.
  addReexportAlias(symbols, "walkDir", "std/os")
  addReexportAlias(symbols, "walkDirRec", "std/os")

  var root = newJObject()
  root["generator"] = %"gen_stdlib_map.nim"
  root["nimVersion"] = %nimVersion
  root["implicitModules"] = %*["std/system"]
  root["modules"] = newJObject()
  var moduleNames = toSeq(tables.keys(modules))
  moduleNames.sort
  for module in moduleNames:
    root["modules"][module] = %true

  root["symbols"] = newJObject()
  var symbolNames = toSeq(tables.keys(symbols))
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
  let binaryPath = binaryOutputPath(config.outputPath)
  writeStdlibBinary(root, binaryPath)
  echo "documented ",
    documented, "/", files.len, " modules; wrote ", config.outputPath, " and ",
    binaryPath, " (", symbols.len, " symbol names)"

when isMainModule:
  let config = parseConfig()
  let discovered = discoverNimConfig()
  generate(config, discovered.nimVersion)
