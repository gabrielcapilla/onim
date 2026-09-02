import std/os except walkDir
from std/os import walkDir

for k, v in walkDir("/tmp"):
  echo k
