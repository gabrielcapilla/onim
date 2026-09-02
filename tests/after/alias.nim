import std/os as filesystem

for k, v in filesystem.walkDir("/tmp"):
  echo k
