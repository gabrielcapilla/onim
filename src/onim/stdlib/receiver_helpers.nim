import std/strutils

import ../index/surfaces
import ../syntax/tokens

proc firstParameterType*(signature: string): string {.inline.} =
  let open = signature.find('(')
  if open < 0:
    return
  let colon = signature.find(':', open + 1)
  if colon < 0:
    return
  let semicolon = signature.find(';', colon + 1)
  let close = signature.find(')', colon + 1)
  var past = semicolon
  if past < 0 or (close >= 0 and close < past):
    past = close
  if past > colon + 1:
    result = signature[colon + 1 ..< past].strip

proc callableCandidate*(kind: string): bool {.inline.} =
  case kind
  of "skProc", "skFunc", "skIterator", "skMethod", "skMacro", "skTemplate",
      "skConverter":
    true
  else:
    false

proc receiverIndexKey*(module, nominal: string): string {.inline.} =
  let canonical = canonicalSurfaceModule(module)
  let key = identifierKey(nominal)
  if canonical.len == 0 or key.len == 0:
    return
  canonical & "|" & key

proc plainNominalName*(value: string): bool {.inline.} =
  if value.len == 0 or not (value[0].isAlphaAscii or value[0] == '_'):
    return false
  for character in value[1 .. ^1]:
    if not (character.isAlphaAscii or character.isDigit or character == '_'):
      return false
  true
