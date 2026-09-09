import std/strutils

proc stripFinalNewline*(value, newline: string): string =
  result = value
  if result.endsWith(newline):
    result.setLen(result.len - newline.len)

proc indentImportText*(value, indent, newline: string): string =
  let hasFinalNewline = value.endsWith(newline)
  var body = stripFinalNewline(value, newline)
  body = body.replace(newline, newline & indent)
  result = body
  if hasFinalNewline:
    result.add newline
