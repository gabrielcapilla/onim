import std/[os, strutils]

proc canonicalPath*(path: string): string =
  if path.len == 0:
    return ""
  absolutePath(path).replace('\\', '/')

proc pathWithin*(root, path: string): bool {.inline.} =
  if root == "/":
    return path.startsWith("/")
  path == root or path.startsWith(root & "/")
