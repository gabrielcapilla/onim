import std/[os, strformat, tables]

proc main() =
  echo fmt("hi")
  for k, v in walkDir("/tmp"):
    discard k
