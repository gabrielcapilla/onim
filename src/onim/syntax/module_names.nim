import std/strutils

import ./tokens

proc canonicalReference*(module: string): string =
  result = module.strip(chars = {'"', '\'', '`'})
  result = result.replace('\\', '/')
  var prefix = ""
  if result.len > 3 and result.startsWith("../"):
    prefix = "../"
    result = result[3 .. ^1]
  elif result.len > 2 and result.startsWith("./"):
    prefix = "./"
    result = result[2 .. ^1]
  if result.toLowerAscii.endsWith(".nim"):
    result.setLen(result.len - 4)
  result = result.replace('.', '/')
  while result.contains("//"):
    result = result.replace("//", "/")
  result = prefix & result

proc moduleLeaf*(module: string): string =
  var normalized = module.strip(chars = {'"', '\'', '`'}).replace('\\', '/')
  normalized = normalized.replace('.', '/')
  let slash = normalized.rfind('/')
  if slash >= 0 and slash + 1 < normalized.len:
    normalized = normalized[slash + 1 .. ^1]
  if normalized.toLowerAscii.endsWith(".nim"):
    normalized.setLen(normalized.len - 4)
  normalized

proc moduleBase*(module: string): string =
  moduleLeaf(module)

proc moduleText*(tokens: TokenStore, first, last: int): string =
  for index in first ..< last:
    if tokens.tokenTextEquals(tokens[index], "."):
      result.add '/'
    else:
      result.add tokens.tokenText(tokens[index])
