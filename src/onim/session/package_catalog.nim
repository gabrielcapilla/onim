import std/[algorithm, os, strutils]

import ../syntax/tokens
import ../syntax/lexer
import ./discovery_budget
import ./paths

type
  NimblePackageResolutionKind* = enum
    packageUnknown
    packageMissing
    packageAmbiguous
    packageResolved

  NimblePackage* = object
    name*: string
    version*: string
    root*: string
    sourceRoot*: string

  NimblePackageResolution* = object
    kind*: NimblePackageResolutionKind
    name*: string
    selected*: NimblePackage
    candidates*: seq[NimblePackage]

  RequirementState = enum
    requirementInvalid
    requirementIgnored
    requirementValid

  NimbleRequirement = object
    name: string
    operator: string
    version: string

  PackageCancellation = proc(): bool {.gcsafe.}

proc addUnique(values: var seq[string], value: string) =
  if value.len == 0:
    return
  for existing in values:
    if existing == value:
      return
  values.add value

proc requirementValue(
    value: string
): tuple[state: RequirementState, value: NimbleRequirement] =
  let parts = value.strip.splitWhitespace
  if parts.len == 0:
    return
  result.value.name = parts[0].toLowerAscii
  if result.value.name == "nim":
    result.state = requirementIgnored
    return
  if parts.len == 1:
    result.state = requirementValid
    return
  if parts.len != 3 or parts[1] notin ["=", "==", ">=", "<=", ">", "<"]:
    return
  result.value.operator = parts[1]
  result.value.version = parts[2]
  if result.value.version.len > 0:
    result.state = requirementValid

proc declaredRequirements(
    configPath: string
): tuple[state: RequirementState, values: seq[NimbleRequirement]] =
  var source: string
  try:
    source = readFile(configPath)
  except CatchableError:
    return
  let tokens = lex(source)
  for index, token in tokens:
    if token.kind != tkIdentifier or not tokens.tokenTextEquals(token, "requires"):
      continue
    var cursor = index + 1
    if cursor < tokens.len and tokens.tokenTextEquals(tokens[cursor], "("):
      inc cursor
    var found = false
    while cursor < tokens.len:
      let current = tokens[cursor]
      if current.line != token.line and found:
        break
      if current.kind == tkString:
        let parsed = requirementValue(tokens.stringLiteralValue(current))
        case parsed.state
        of requirementInvalid:
          result.state = requirementInvalid
          return
        of requirementIgnored:
          discard
        of requirementValid:
          result.values.add parsed.value
        found = true
        inc cursor
        continue
      if tokens.tokenTextEquals(current, ",") or tokens.tokenTextEquals(current, "("):
        inc cursor
        continue
      if tokens.tokenTextEquals(current, ")"):
        break
      if current.line != token.line:
        result.state = requirementInvalid
        return
      break
    if not found:
      result.state = requirementInvalid
      return
  result.state = requirementValid

proc manifestValue(
    configPath, name: string
): tuple[state: RequirementState, value: string] =
  var source: string
  try:
    source = readFile(configPath)
  except CatchableError:
    return
  let tokens = lex(source)
  for index, token in tokens:
    if token.kind != tkIdentifier or not tokens.tokenTextEquals(token, name):
      continue
    if index + 2 >= tokens.len or not tokens.tokenTextEquals(tokens[index + 1], "="):
      result.state = requirementInvalid
      return
    let value = tokens.stringLiteralValue(tokens[index + 2])
    if value.len == 0:
      result.state = requirementInvalid
      return
    result.state = requirementValid
    result.value = value
    return
  result.state = requirementIgnored

proc versionParts(value: string): seq[uint32] =
  for part in value.split('.'):
    var digits = ""
    for character in part:
      if character notin {'0' .. '9'}:
        break
      digits.add character
    if digits.len == 0:
      return @[]
    try:
      result.add uint32(parseUInt(digits))
    except ValueError:
      return @[]

proc compareVersions(left, right: string): int =
  let leftParts = versionParts(left)
  let rightParts = versionParts(right)
  if leftParts.len == 0 or rightParts.len == 0:
    return cmp(left, right)
  let count = max(leftParts.len, rightParts.len)
  for index in 0 ..< count:
    let leftPart =
      if index < leftParts.len:
        leftParts[index]
      else:
        0'u32
    let rightPart =
      if index < rightParts.len:
        rightParts[index]
      else:
        0'u32
    if leftPart != rightPart:
      return cmp(leftPart, rightPart)

proc satisfies(version, operator, wanted: string): bool =
  let comparison = compareVersions(version, wanted)
  case operator
  of "=", "==":
    comparison == 0
  of ">=":
    comparison >= 0
  of "<=":
    comparison <= 0
  of ">":
    comparison > 0
  of "<":
    comparison < 0
  else:
    false

proc nimbleStore(): string =
  var root = getEnv("NIMBLE_DIR")
  if root.len == 0:
    root = getHomeDir() / ".nimble"
  result = canonicalPath(root) / "pkgs2"

proc packageFromManifest(
    configPath: string
): tuple[state: RequirementState, package: NimblePackage] =
  let packageRoot = canonicalPath(splitFile(configPath).dir)
  if packageRoot.len == 0:
    return
  let name = splitFile(configPath).name.toLowerAscii
  let version = manifestValue(configPath, "version")
  if version.state != requirementValid:
    return
  let source = manifestValue(configPath, "srcDir")
  result.package.name = name
  result.package.version = version.value
  result.package.root = packageRoot
  if source.state == requirementIgnored:
    result.package.sourceRoot = packageRoot
  elif source.state == requirementValid:
    if isAbsolute(source.value):
      result.package.sourceRoot = canonicalPath(source.value)
    else:
      result.package.sourceRoot = canonicalPath(packageRoot / source.value)
  else:
    return
  if not dirExists(result.package.sourceRoot):
    return
  result.state = requirementValid

proc packageCandidates(
    requirement: NimbleRequirement,
    budget: var DiscoveryBudget,
    cancellation: PackageCancellation,
): tuple[
  state: RequirementState,
  candidates: seq[NimblePackage],
  cancelled: bool,
  limited: bool,
] =
  result.state = requirementValid
  let store = nimbleStore()
  if not dirExists(store):
    return
  try:
    for kind, path in walkDir(store):
      if cancellation != nil and cancellation():
        result.cancelled = true
        return
      if not budget.admitEntry():
        result.limited = true
        return
      case kind
      of pcDir:
        if not budget.admitDirectory():
          result.limited = true
          return
      of pcFile:
        if not budget.admitFile():
          result.limited = true
          return
      else:
        discard
      if kind != pcDir:
        continue
      let configPath = path / (requirement.name & ".nimble")
      if not fileExists(configPath):
        continue
      let candidate = packageFromManifest(configPath)
      if candidate.state != requirementValid:
        result.state = requirementInvalid
      elif candidate.package.name == requirement.name and
          satisfies(
            candidate.package.version, requirement.operator, requirement.version
          ):
        result.candidates.add candidate.package
  except CatchableError:
    result.state = requirementInvalid
    result.candidates.setLen(0)
  if result.state == requirementInvalid:
    return
  result.state = requirementValid

proc resolveRequirement(
    requirement: NimbleRequirement,
    budget: var DiscoveryBudget,
    cancellation: PackageCancellation,
): tuple[value: NimblePackageResolution, cancelled: bool, limited: bool] =
  result.value.name = requirement.name
  let available = packageCandidates(requirement, budget, cancellation)
  result.cancelled = available.cancelled
  result.limited = available.limited
  if result.cancelled or result.limited:
    return
  if available.state == requirementInvalid:
    result.value.kind = packageUnknown
    return
  result.value.candidates = available.candidates
  if result.value.candidates.len == 0:
    result.value.kind = packageMissing
    return
  result.value.candidates.sort(
    proc(left, right: NimblePackage): int =
      let byVersion = compareVersions(right.version, left.version)
      if byVersion != 0:
        byVersion
      else:
        cmp(left.root, right.root)
  )
  let best = result.value.candidates[0]
  if result.value.candidates.len > 1 and
      compareVersions(best.version, result.value.candidates[1].version) == 0:
    result.value.kind = packageAmbiguous
    return
  result.value.kind = packageResolved
  result.value.selected = best

proc declaredNimblePackagesBounded(
    root: string, budget: var DiscoveryBudget, cancellation: PackageCancellation
): tuple[values: seq[NimblePackageResolution], cancelled: bool, limited: bool] =
  let canonicalRoot = canonicalPath(root)
  if canonicalRoot.len == 0 or not dirExists(canonicalRoot):
    return
  try:
    for kind, path in walkDir(canonicalRoot):
      if cancellation != nil and cancellation():
        result.cancelled = true
        return
      if not budget.admitEntry():
        result.limited = true
        return
      case kind
      of pcDir:
        if not budget.admitDirectory():
          result.limited = true
          return
      of pcFile:
        if not budget.admitFile():
          result.limited = true
          return
      else:
        discard
      if kind != pcFile or not path.toLowerAscii.endsWith(".nimble"):
        continue
      let requirements = declaredRequirements(path)
      if requirements.state != requirementValid:
        result.values.add NimblePackageResolution(kind: packageUnknown)
        continue
      for requirement in requirements.values:
        let resolution = resolveRequirement(requirement, budget, cancellation)
        if resolution.cancelled or resolution.limited:
          result.cancelled = resolution.cancelled
          result.limited = resolution.limited
          return
        result.values.add resolution.value
  except CatchableError:
    result.values.setLen(0)

proc declaredNimblePackages*(root: string): seq[NimblePackageResolution] =
  var budget = initDiscoveryBudget()
  let scanned = declaredNimblePackagesBounded(root, budget, nil)
  if scanned.cancelled or scanned.limited:
    return
  scanned.values

proc nimbleDependencyRoots*(root: string): seq[string] =
  for resolution in declaredNimblePackages(root):
    if resolution.kind == packageResolved:
      result.add resolution.selected.sourceRoot

proc nimbleDependencySourcesBounded*(
    root: string, budget: var DiscoveryBudget, cancellation: proc(): bool {.gcsafe.}
): tuple[paths: seq[string], cancelled: bool, limited: bool] =
  let packages = declaredNimblePackagesBounded(root, budget, cancellation)
  if packages.cancelled or packages.limited:
    result.cancelled = packages.cancelled
    result.limited = packages.limited
    return
  for resolution in packages.values:
    if resolution.kind != packageResolved:
      continue
    let sourceRoot = resolution.selected.sourceRoot
    if cancellation != nil and cancellation():
      result.cancelled = true
      return
    if not budget.admitDirectory():
      result.limited = true
      return
    try:
      for path in walkDirRec(sourceRoot, yieldFilter = {pcFile, pcDir}):
        if cancellation != nil and cancellation():
          result.cancelled = true
          return
        if not budget.admitEntry():
          result.limited = true
          return
        if dirExists(path):
          if not budget.admitDirectory():
            result.limited = true
            return
        elif fileExists(path):
          if not budget.admitFile():
            result.limited = true
            return
          if path.toLowerAscii.endsWith(".nim"):
            addUnique(result.paths, canonicalPath(path))
    except CatchableError:
      result.paths.setLen(0)
      return
  result.paths.sort

proc nimbleDependencySources*(root: string): seq[string] =
  var budget = initDiscoveryBudget()
  let scanned = nimbleDependencySourcesBounded(root, budget, nil)
  if scanned.cancelled or scanned.limited:
    return
  scanned.paths
