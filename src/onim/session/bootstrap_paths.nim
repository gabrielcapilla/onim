import std/strutils

import ./package_catalog
import ./paths

proc validBootstrapPath*(root, path: string): bool =
  if pathWithin(root, path):
    return path != root
  if not path.toLowerAscii.endsWith(".nim"):
    return false
  for dependencyRoot in nimbleDependencyRoots(root):
    if pathWithin(dependencyRoot, path):
      return true
  false

proc validBootstrapDirectoryPath*(root, path: string): bool =
  path == root or pathWithin(root, path)
