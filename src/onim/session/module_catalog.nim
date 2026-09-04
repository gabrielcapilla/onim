import std/[algorithm, strutils, tables]
import std/os except FileId

import ../syntax/lexer
import ./ids
import ./paths

type
  ModuleFile* = object
    id*: FileId
    path*: string

  ModuleResolutionKind* = enum
    moduleUnknown
    moduleMissing
    moduleAmbiguous
    moduleResolved

  ModuleResolution* = object
    kind*: ModuleResolutionKind
    module*: string
    id*: FileId
    candidates*: seq[FileId]

  ModuleCatalog* = ref object
    roots: seq[string]
    byModule: Table[string, seq[FileId]]
    byPath: Table[string, FileId]
    moduleByPath: Table[string, string]
    complete: bool

proc canonicalModuleName*(module: string): string =
  var normalized = module.strip(chars = {'"', '\'', '`'}).replace('\\', '/')
  var prefix = ""
  if normalized.startsWith("../"):
    prefix = "../"
    normalized = normalized[3 .. ^1]
  elif normalized.startsWith("./"):
    prefix = "./"
    normalized = normalized[2 .. ^1]
  if normalized.toLowerAscii.endsWith(".nim"):
    normalized.setLen(normalized.len - 4)
  normalized = normalized.replace('.', '/')
  while normalized.contains("//"):
    normalized = normalized.replace("//", "/")
  prefix & normalized

proc pathString(token: Token): string =
  if token.kind != tkString or token.text.len < 2:
    return ""
  let quote = token.text[0]
  if (quote != '"' and quote != char(39)) or token.text[^1] != quote:
    return ""
  token.text[1 ..< token.text.len - 1]

proc tokenPathValue(token: Token): string =
  let quoted = pathString(token)
  if quoted.len > 0:
    return quoted
  if token.kind == tkIdentifier and token.keyword == kwNone:
    return token.text

proc addRoot(catalog: ModuleCatalog, path: string) =
  let root = canonicalPath(path)
  if root.len == 0:
    return
  for existing in catalog.roots:
    if existing == root:
      return
  catalog.roots.add root

proc addConfiguredRoot(catalog: ModuleCatalog, configPath, value: string) =
  if value.len == 0:
    return
  if isAbsolute(value):
    catalog.addRoot(value)
  else:
    catalog.addRoot(splitFile(configPath).dir / value)

proc addNimbleRoots(catalog: ModuleCatalog, configPath: string): bool =
  var source: string
  try:
    source = readFile(configPath)
  except CatchableError:
    return false
  let tokens = lex(source)
  var sawSourceDirectory = false
  for index, token in tokens:
    if token.kind != tkIdentifier or token.text != "srcDir":
      continue
    sawSourceDirectory = true
    var cursor = index + 1
    while cursor < tokens.len and tokens[cursor].line == token.line and
        tokens[cursor].text != "=":
      inc cursor
    if cursor + 1 >= tokens.len or tokens[cursor].text != "=":
      return false
    let value = pathString(tokens[cursor + 1])
    if value.len == 0:
      return false
    catalog.addConfiguredRoot(configPath, value)
  not sawSourceDirectory or catalog.roots.len > 0

proc addNimConfigRoots(catalog: ModuleCatalog, configPath: string) =
  var source: string
  try:
    source = readFile(configPath)
  except CatchableError:
    return
  let tokens = lex(source)
  for index, token in tokens:
    if token.kind != tkIdentifier or token.text != "path":
      continue
    if index + 2 >= tokens.len or
        (tokens[index + 1].text != ":" and tokens[index + 1].text != "="):
      continue
    let value = tokenPathValue(tokens[index + 2])
    if value.len > 0:
      catalog.addConfiguredRoot(configPath, value)

proc configureRoots(catalog: ModuleCatalog, root: string) =
  let canonicalRoot = canonicalPath(root)
  if canonicalRoot.len == 0:
    return
  catalog.addRoot(canonicalRoot)
  let conventional = canonicalRoot / "src"
  if dirExists(conventional):
    catalog.addRoot(conventional)

  try:
    for kind, path in walkDir(canonicalRoot):
      if kind == pcFile and path.toLowerAscii.endsWith(".nimble") and
          not catalog.addNimbleRoots(path):
        catalog.complete = false
  except CatchableError:
    catalog.complete = false

  let compilerConfig = canonicalRoot / "nim.cfg"
  if fileExists(compilerConfig):
    catalog.addNimConfigRoots(compilerConfig)

  # config.nims is executable Nim code. Without evaluating it, its import
  # paths are not a complete description of the compiler's search path.
  if fileExists(canonicalRoot / "config.nims"):
    catalog.complete = false

proc moduleForPath*(catalog: ModuleCatalog, path: string): string =
  if catalog == nil:
    return
  let normalizedPath = canonicalPath(path)
  var selectedRoot = ""
  for root in catalog.roots:
    if normalizedPath == root or (
      normalizedPath.len > root.len and normalizedPath.startsWith(root) and
      normalizedPath[root.len] in {'/', '\\'}
    ):
      if root.len > selectedRoot.len:
        selectedRoot = root
  if selectedRoot.len == 0 or normalizedPath.len <= selectedRoot.len:
    return
  var relative = normalizedPath[selectedRoot.len + 1 .. ^1]
  if relative.toLowerAscii.endsWith(".nim"):
    relative.setLen(relative.len - 4)
  canonicalModuleName(relative)

proc modulePath(reference: string): string =
  let normalized = reference.strip(chars = {'"', '\'', '`'}).replace('\\', '/')
  if normalized.startsWith("./") or normalized.startsWith("../"):
    return canonicalModuleName(normalized)
  canonicalModuleName(normalized)

proc addCandidate(candidates: var seq[FileId], id: FileId) =
  if not id.valid:
    return
  for existing in candidates:
    if uint32(existing) == uint32(id):
      return
  candidates.add id

proc candidatePath(path: string): string =
  result = canonicalPath(path)
  if result.len > 0 and not result.toLowerAscii.endsWith(".nim"):
    result.add ".nim"

proc completeResolution(catalog: ModuleCatalog, module: string): ModuleResolution =
  result.module = module
  if catalog == nil or not catalog.complete:
    result.kind = moduleUnknown
    return
  if not catalog.byModule.hasKey(module):
    result.kind = moduleMissing
    return
  result.candidates = catalog.byModule[module]
  case result.candidates.len
  of 0:
    result.kind = moduleMissing
  of 1:
    result.kind = moduleResolved
    result.id = result.candidates[0]
  else:
    result.kind = moduleAmbiguous

proc resolve*(
    catalog: ModuleCatalog, ownerPath, reference: string
): ModuleResolution {.gcsafe.} =
  if catalog == nil or not catalog.complete:
    result.kind = moduleUnknown
    return
  let normalized = reference.strip
  if normalized.len == 0:
    result.kind = moduleMissing
    return
  let relative = normalized.startsWith("./") or normalized.startsWith("../")
  var candidates: seq[string] = @[]
  if isAbsolute(normalized):
    candidates.add normalized
  else:
    candidates.add splitFile(ownerPath).dir / modulePath(normalized)
    if not relative:
      for root in catalog.roots:
        candidates.add root / modulePath(normalized)

  for path in candidates:
    let key = candidatePath(path)
    if catalog.byPath.hasKey(key):
      result.kind = moduleResolved
      result.id = catalog.byPath[key]
      if catalog.moduleByPath.hasKey(key):
        result.module = catalog.moduleByPath[key]
      result.candidates = @[result.id]
      return
  result.kind = moduleMissing

proc relativeModule(owner, reference: string): string =
  let target = modulePath(reference)
  let slash = owner.rfind('/')
  var parent =
    if slash >= 0:
      owner[0 ..< slash]
    else:
      ""
  if reference.startsWith("../"):
    parent = parent & "/../" & target[3 .. ^1]
  elif reference.startsWith("./"):
    parent = parent & "/" & target[2 .. ^1]
  else:
    parent = parent & "/" & target

  var parts: seq[string] = @[]
  for part in parent.split('/'):
    case part
    of "", ".":
      discard
    of "..":
      if parts.len > 0:
        parts.setLen(parts.len - 1)
    else:
      parts.add part
  parts.join("/")

proc resolveModuleName*(
    catalog: ModuleCatalog, owner, reference: string
): ModuleResolution =
  if catalog == nil or not catalog.complete:
    result.kind = moduleUnknown
    return
  let target = modulePath(reference)
  if target.len == 0:
    result.kind = moduleMissing
    return
  if reference.startsWith("./") or reference.startsWith("../"):
    return catalog.completeResolution(relativeModule(owner, reference))

  let local = relativeModule(owner, reference)
  if catalog.byModule.hasKey(local):
    return catalog.completeResolution(local)
  catalog.completeResolution(target)

proc valid*(catalog: ModuleCatalog): bool =
  catalog != nil

proc complete*(catalog: ModuleCatalog): bool =
  catalog != nil and catalog.complete

proc rootCount*(catalog: ModuleCatalog): int =
  if catalog != nil:
    result = catalog.roots.len

proc rootAt*(catalog: ModuleCatalog, index: int): string =
  if catalog != nil and index >= 0 and index < catalog.roots.len:
    result = catalog.roots[index]

proc candidateCount*(catalog: ModuleCatalog, module: string): int =
  if catalog != nil and catalog.byModule.hasKey(canonicalModuleName(module)):
    result = catalog.byModule[canonicalModuleName(module)].len

proc buildModuleCatalog*(
    root: string, files: openArray[ModuleFile]
): ModuleCatalog {.gcsafe.} =
  new(result)
  result.roots = @[]
  result.byModule = initTable[string, seq[FileId]]()
  result.byPath = initTable[string, FileId]()
  result.moduleByPath = initTable[string, string]()
  result.complete = true
  configureRoots(result, root)

  for file in files:
    let path = canonicalPath(file.path)
    let module = result.moduleForPath(path)
    if path.len == 0:
      continue
    result.byPath[path] = file.id
    if module.len > 0:
      result.moduleByPath[path] = module
      result.byModule.mgetOrPut(module, @[]).addCandidate(file.id)

  for module, ids in result.byModule.mpairs:
    ids.sort(
      proc(left, right: FileId): int =
        cmp(uint32(left), uint32(right))
    )
