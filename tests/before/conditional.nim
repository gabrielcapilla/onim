when defined(posix):
  import std/os

for k, v in walkDir("/tmp"):
  echo k
