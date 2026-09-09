import std/[os, strutils]

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
  try:
    for kind, path in walkDir(root):
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
