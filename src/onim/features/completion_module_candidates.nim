import std/tables

import ./completion_candidates
import ./completion_stdlib_module
import ../index/surfaces
import ../index/surface_resolution
import ../stdlib/map
import ../syntax/module_names
import ../syntax/tokens

proc appendProjectMembers*(
    input: SurfaceInput,
    prefixKey: string,
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
): bool =
  if input.module.len == 0 or input.uncertainty != {}:
    return false
  for exported in input.exports:
    if not exported.kindKnown or identifierKey(exported.name).len == 0:
      return false
    discard appendCompletionCandidate(
      exported.name,
      memberCompletionKind(exported.kind),
      prefixKey,
      candidates,
      candidateByName,
    )
  true

proc appendStdlibMembers*(
    stdlib: StdlibMap,
    module, prefix: string,
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
): bool =
  let moduleName = stdlib.stdlibModuleName(module)
  if moduleName.len == 0:
    return false
  let surface = stdlib.surfaceIndex()
  var bindings: seq[BindingCandidate] = @[]
  if not surface.appendBindingsInModule(moduleName, prefix, bindings):
    return false
  for binding in bindings:
    let exports = surface.exportsFor(binding)
    if exports.len == 0:
      return false
    var appended = false
    for candidate in stdlib.candidatesFor(binding.name, moduleBase(moduleName), -1):
      if not sameModule(candidate.module, moduleName):
        continue
      appended = true
      discard appendStdlibCandidate(
        candidate,
        memberCompletionKind(exports[0].kind),
        identifierKey(prefix),
        candidates,
        candidateByName,
      )
    if not appended:
      discard appendCompletionCandidate(
        binding.name,
        memberCompletionKind(exports[0].kind),
        identifierKey(prefix),
        candidates,
        candidateByName,
      )
  true
