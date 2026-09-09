import std/algorithm

import ./map

proc resolveUniqueCandidate*(
  stdlib: StdlibMap, name, qualifier: string, arity = -1
): tuple[state: CandidateResolutionState, candidate: SymbolCandidate]

proc resolveCandidate*(
    stdlib: StdlibMap, name, qualifier: string, arity = -1
): SymbolCandidate =
  let candidates = stdlib.candidatesFor(name, qualifier, arity)
  if candidates.len == 0:
    return
  let unique = stdlib.resolveUniqueCandidate(name, qualifier, arity)
  if unique.state == candidateResolutionResolved:
    return unique.candidate
  var ordered = candidates
  ordered.sort(
    proc(left, right: SymbolCandidate): int =
      cmp(left.module, right.module)
  )
  ordered[0]

proc resolveUniqueCandidate*(
    stdlib: StdlibMap, name, qualifier: string, arity = -1
): tuple[state: CandidateResolutionState, candidate: SymbolCandidate] =
  ## Resolve only when the map gives one safe module identity. The legacy
  ## `resolveCandidate` API remains available for callers that explicitly
  ## accept its deterministic fallback; semantic features use this stricter
  ## result so a collision cannot become an unsafe edit or diagnostic.
  let candidates = stdlib.candidatesFor(name, qualifier, arity)
  if candidates.len == 0:
    return

  if qualifier.len == 0:
    var canonicalModuleName = ""
    var canonicalFound = false
    var canonicalCandidate: SymbolCandidate
    for candidate in stdlib.candidatesFor(name, "", -1):
      if candidate.priority != candidateCanonical:
        continue
      let module = canonicalModule(candidate.module)
      if not canonicalFound:
        canonicalModuleName = module
        canonicalCandidate = candidate
        canonicalFound = true
      elif module != canonicalModuleName:
        return (candidateResolutionAmbiguous, SymbolCandidate())
    if canonicalFound:
      return (candidateResolutionResolved, canonicalCandidate)

  if candidates.len == 1:
    return (candidateResolutionResolved, candidates[0])

  let firstModule = canonicalModule(candidates[0].module)
  var sameModule = true
  for candidate in candidates[1 .. ^1]:
    if canonicalModule(candidate.module) != firstModule:
      sameModule = false
      break
  if sameModule:
    return (candidateResolutionResolved, candidates[0])

  result.state = candidateResolutionAmbiguous
