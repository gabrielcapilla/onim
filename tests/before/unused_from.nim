from std/os import walkDir, walkFiles

proc main() =
  for kind, path in walkDir("/tmp"):
    discard kind
