import std/tables

var values: Table[string, int]
for k, v in walkDir("/tmp"):
  echo k
