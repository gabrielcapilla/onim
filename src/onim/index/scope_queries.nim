import std/tables

import ./scopes

proc isComplete*(index: ScopeIndex): bool =
  index.uncertainty == {}

proc declarationOrdinalAt*(index: ScopeIndex, nameToken: uint32): int {.inline.} =
  var first = 0
  var past = index.declarations.len
  while first < past:
    let middle = (first + past) div 2
    let candidate = index.declarations[middle].nameToken
    if candidate < nameToken:
      first = middle + 1
    elif candidate > nameToken:
      past = middle
    else:
      return middle
  -1

proc parentScope*(index: ScopeIndex, scope: ScopeId): ScopeId {.inline.} =
  let ordinal = int(uint32(scope)) - 1
  if ordinal >= 0 and ordinal < index.scopes.len:
    return index.scopes[ordinal].parent
  InvalidScopeId

proc isLocalScope*(index: ScopeIndex, scope: ScopeId): bool {.inline.} =
  let ordinal = int(uint32(scope)) - 1
  ordinal > 0 and ordinal < index.scopes.len and
    index.scopes[ordinal].kind in {scopeRoutine, scopeBlock}

proc addScopeDistances*(
    index: ScopeIndex, active: ScopeId, distances: var Table[uint32, uint32]
): bool =
  var current = active
  while current != InvalidScopeId:
    let ordinal = current.scopeOrdinal
    if ordinal < 0 or ordinal >= index.scopes.len:
      return false
    let scope = index.scopes[ordinal]
    if scope.kind == scopeModule:
      return distances.len > 0
    if scope.kind notin {scopeRoutine, scopeBlock}:
      return false
    distances[uint32(current)] = uint32(distances.len)
    current = index.parentScope(current)
  false

proc isScopeAncestor*(index: ScopeIndex, ancestor, descendant: ScopeId): bool =
  var current = descendant
  while current != InvalidScopeId:
    if current == ancestor:
      return true
    current = index.parentScope(current)
  false
