import std/strutils
import std/tables

import ../index/surfaces
import ../syntax/module_names
import ../syntax/tokens
import ./map
import ./receiver_helpers

proc implicitValueCandidate*(stdlib: StdlibMap, name: string): SymbolCandidate =
  if stdlib == nil or not stdlib.implicitModule("std/system"):
    return
  for candidate in stdlib.candidatesFor(name, "", -1):
    if candidate.kind != "skVar" or not candidate.signature.endsWith("}: File"):
      continue
    if result.module.len > 0:
      return SymbolCandidate()
    result = candidate

proc implicitFileModule(stdlib: StdlibMap, name: string): string =
  let candidate = stdlib.implicitValueCandidate(name)
  if candidate.module.len > 0:
    result = canonicalModule(candidate.module)

proc implicitFileModule(stdlib: StdlibMap): string =
  if stdlib == nil or not stdlib.implicitModule("std/system"):
    return
  for _, candidates in stdlib.symbols:
    for candidate in candidates:
      if candidate.kind != "skVar" or not candidate.signature.endsWith("}: File"):
        continue
      let module = canonicalModule(candidate.module)
      if result.len == 0:
        result = module
      elif result != module:
        return ""

proc fileMembersForModule(
    stdlib: StdlibMap, module, prefix: string
): seq[SymbolCandidate] =
  if module.len == 0:
    return
  let prefixKey = identifierKey(prefix)
  let receiverKey = receiverIndexKey(module, "File")
  if not stdlib.receiverCandidates.hasKey(receiverKey):
    return
  for candidate in stdlib.receiverCandidates[receiverKey]:
    let key = identifierKey(candidate.name)
    if key.len == 0 or (prefixKey.len > 0 and not key.startsWith(prefixKey)):
      continue
    discard addUniqueCandidate(result, candidate)

proc implicitFileMembers*(
    stdlib: StdlibMap, name, prefix: string
): seq[SymbolCandidate] =
  stdlib.fileMembersForModule(stdlib.implicitFileModule(name), prefix)

proc implicitFileMembers*(stdlib: StdlibMap, prefix: string): seq[SymbolCandidate] =
  stdlib.fileMembersForModule(stdlib.implicitFileModule(), prefix)

proc directNominalMembers*(
    stdlib: StdlibMap, module, nominal, prefix: string
): seq[SymbolCandidate] =
  if stdlib == nil:
    return
  let canonical = canonicalModule(module)
  if not canonical.startsWith("std/") or nominal.len == 0:
    return
  let prefixKey = identifierKey(prefix)
  let receiverKey = receiverIndexKey(canonical, nominal)
  if not stdlib.receiverCandidates.hasKey(receiverKey):
    return
  for candidate in stdlib.receiverCandidates[receiverKey]:
    let key = identifierKey(candidate.name)
    if key.len == 0 or (prefixKey.len > 0 and not key.startsWith(prefixKey)):
      continue
    discard addUniqueCandidate(result, candidate)
