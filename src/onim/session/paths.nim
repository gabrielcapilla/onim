import std/[os, strutils]

import ./discovery_budget

proc canonicalPath*(path: string): string =
  if path.len == 0:
    return ""
  absolutePath(path).replace('\\', '/')

proc pathWithin*(root, path: string): bool {.inline.} =
  if root == "/":
    return path.startsWith("/")
  path == root or path.startsWith(root & "/")

proc broadWorkspaceRoot*(path: string): bool =
  let root = canonicalPath(path)
  root == "/" or root == canonicalPath(getHomeDir())

proc hasProjectMarker*(root: string): bool =
  if root.len == 0 or not dirExists(root):
    return false
  if fileExists(root / "nim.cfg") or fileExists(root / "config.nims"):
    return true
  var budget = initDiscoveryBudget()
  try:
    for kind, path in walkDir(root):
      if not budget.admitEntry():
        return false
      case kind
      of pcDir:
        if not budget.admitDirectory():
          return false
      of pcFile:
        if not budget.admitFile():
          return false
      else:
        discard
      if kind == pcFile and path.toLowerAscii.endsWith(".nimble"):
        return true
  except CatchableError:
    discard
  false

proc nearestProjectRoot*(path: string): string =
  var current = canonicalPath(path)
  if current.len == 0:
    return
  if fileExists(current):
    current = parentDir(current)
  while current.len > 0:
    if hasProjectMarker(current):
      return current
    let parent = parentDir(current)
    if parent == current:
      break
    current = parent
