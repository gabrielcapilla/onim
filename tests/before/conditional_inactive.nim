when defined(windows):
  import std/os

for k, v in walkDir("/tmp"):
  echo k
