import std/os

proc main() =
  echo fmt("hi")
  for k, v in walkDir("/tmp"):
    discard k
