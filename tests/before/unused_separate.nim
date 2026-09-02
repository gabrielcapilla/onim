import std/os
import std/strformat
import std/tables

proc main() =
  echo fmt("hi")
  for k, v in walkDir("/tmp"):
    discard k
