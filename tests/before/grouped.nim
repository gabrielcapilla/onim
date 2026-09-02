import std/[json, tables]

let document = parseJson("{}")
var values: Table[string, int]
for k, v in walkDir("/tmp"):
  echo k
discard document
discard values
