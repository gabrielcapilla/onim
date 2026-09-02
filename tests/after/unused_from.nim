from std/os import walkDir

proc main() =
  for kind, path in walkDir("/tmp"):
    discard kind
