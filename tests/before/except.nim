import std/os except walkDir

for k, v in walkDir("/tmp"):
  echo k
