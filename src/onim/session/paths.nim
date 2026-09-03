import std/[os, strutils]

proc canonicalPath*(path: string): string =
  if path.len == 0:
    return ""
  absolutePath(path).replace('\\', '/')
