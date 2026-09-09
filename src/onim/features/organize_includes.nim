import std/[os, sets, strutils, tables]

import ../index/cache
import ../syntax/imports
import ../syntax/tokens

type IncludedImportCacheEntry = object
  stamp: FileStamp
  imports: SourceImports

const maxIncludedImportCacheEntries = 128

var includedImportCache = initTable[string, IncludedImportCacheEntry]()

proc mergeIncludedNames(target: var SourceImports, source: SourceImports) =
  for name in source.localDefinitions:
    target.localDefinitions.incl name
    target.availableNames.incl name
  for name in source.availableNames:
    target.availableNames.incl name
  for name in source.qualifiedNames:
    target.qualifiedNames.incl name

proc cachedIncludedImports(path: string, imports: var SourceImports): bool =
  let stamp = fileStamp(path)
  if not usableStamp(stamp):
    return false
  if includedImportCache.hasKey(path) and
      sameFileStamp(includedImportCache[path].stamp, stamp):
    imports = cloneSourceImports(includedImportCache[path].imports)
    return true
  try:
    let parsed = parseSourceImports(readFile(path))
    if includedImportCache.len >= maxIncludedImportCacheEntries:
      includedImportCache.clear()
    includedImportCache[path] = IncludedImportCacheEntry(stamp: stamp, imports: parsed)
    imports = cloneSourceImports(parsed)
    true
  except CatchableError:
    false

proc importsAvailableFromIncluded*(
    sourcePath: string,
    info: var SourceImports,
    visited: var HashSet[string],
    depth: int,
) =
  if depth > 8:
    return
  for tokenIndex, token in info.tokens:
    if not token.isKeyword(kwInclude) or tokenIndex + 1 >= info.tokens.len:
      continue
    let includeToken = info.tokens[tokenIndex + 1]
    var includeName =
      info.tokens.tokenText(includeToken).strip(chars = {'"', '\'', '`'})
    if includeName.len == 0:
      continue
    if not includeName.endsWith(".nim"):
      includeName.add ".nim"
    let includePath =
      if isAbsolute(includeName):
        includeName
      else:
        splitFile(sourcePath).dir / includeName
    let absolute = absolutePath(includePath)
    if absolute in visited:
      continue
    visited.incl absolute
    var included: SourceImports
    if not cachedIncludedImports(absolute, included):
      continue
    mergeIncludedNames(info, included)
    var nested = cloneSourceImports(included)
    importsAvailableFromIncluded(absolute, nested, visited, depth + 1)
    mergeIncludedNames(info, nested)
    for item in nested.imports:
      var importedItem = item
      importedItem.synthetic = true
      info.imports.add importedItem
