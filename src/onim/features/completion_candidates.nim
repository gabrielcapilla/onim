import std/[sets, strutils, tables]

import ../index/symbols
import ../stdlib/map
import ../stdlib/map_decode
import ../syntax/tokens
import ./completion_models
import ./signature

type VisibleCompletion* = object
  item*: CompletionItem
  key*: string
  distance*: uint32
  declarationToken*: uint32

proc completionNameUsable*(name: string): bool {.inline.} =
  if name.len == 0:
    return false
  var first = 0
  var past = name.len
  if name.len >= 2 and name[0] == '`' and name[^1] == '`':
    first = 1
    dec past
  if first >= past:
    return false
  let initial = name[first]
  if initial != '_' and not initial.isAlphaAscii and ord(initial) < 128:
    return false
  for index in first + 1 ..< past:
    let character = name[index]
    if character != '_' and not character.isAlphaAscii and not character.isDigit and
        ord(character) < 128:
      return false
  true

proc appendCompletionCandidate*(
    name: string,
    kind: CompletionKind,
    prefixKey: string,
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
    detail = "",
    documentation = "",
    autoImportModule = "",
    callKind = signatureDirectCall,
): bool =
  let key = identifierKey(name)
  if not completionNameUsable(name) or key.len == 0 or
      (prefixKey.len > 0 and not key.startsWith(prefixKey)):
    return true
  let visible = VisibleCompletion(
    item: CompletionItem(
      label: name,
      kind: kind,
      snippetText:
        if kind in {completionFunction, completionMethod}:
          signatureCallSnippet(name, detail, callKind)
        else:
          "",
      detail: detail,
      documentation: documentation,
      autoImportModule: autoImportModule,
    ),
    key: key,
    declarationToken: high(uint32),
  )
  if not candidateByName.hasKey(key):
    candidateByName[key] = candidates.len
    candidates.add visible
  else:
    let existingIndex = candidateByName[key]
    let conflictingSignature = candidates[existingIndex].item.detail != detail
    if conflictingSignature:
      candidates[existingIndex].item.snippetText = ""
    if ord(visible.item.kind) < ord(candidates[existingIndex].item.kind):
      candidates[existingIndex] = visible
      if conflictingSignature:
        candidates[existingIndex].item.snippetText = ""
  true

proc appendStdlibCandidate*(
    candidate: SymbolCandidate,
    kind: CompletionKind,
    prefixKey: string,
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
    callKind = signatureDirectCall,
): bool =
  if candidate.module.startsWith("std/") and candidate.name.startsWith("c_"):
    return true
  appendCompletionCandidate(
    candidate.name,
    kind,
    prefixKey,
    candidates,
    candidateByName,
    candidate.signature,
    candidate.documentation,
    callKind = callKind,
  )

proc appendImportedCandidate*(
    name, providerKey: string,
    kind: CompletionKind,
    prefixKey: string,
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
    importedProviders: var Table[string, string],
    ambiguousNames: var HashSet[string],
    detail = "",
    documentation = "",
): bool =
  let key = identifierKey(name)
  if not completionNameUsable(name) or key.len == 0 or
      (prefixKey.len > 0 and not key.startsWith(prefixKey)):
    return true
  if key in ambiguousNames:
    return true
  if candidateByName.hasKey(key):
    if not importedProviders.hasKey(key):
      return true
    if importedProviders[key] == providerKey:
      if candidates[candidateByName[key]].item.detail != detail:
        candidates[candidateByName[key]].item.snippetText = ""
      return true
    candidates[candidateByName[key]].key = ""
    candidateByName.del(key)
    importedProviders.del(key)
    ambiguousNames.incl(key)
    return true
  discard appendCompletionCandidate(
    name, kind, prefixKey, candidates, candidateByName, detail, documentation
  )
  if candidateByName.hasKey(key):
    importedProviders[key] = providerKey
  true

proc appendImportedStdlibCandidate*(
    candidate: SymbolCandidate,
    providerKey: string,
    kind: CompletionKind,
    prefixKey: string,
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
    importedProviders: var Table[string, string],
    ambiguousNames: var HashSet[string],
): bool =
  if candidate.module.startsWith("std/") and candidate.name.startsWith("c_"):
    return true
  appendImportedCandidate(
    candidate.name, providerKey, kind, prefixKey, candidates, candidateByName,
    importedProviders, ambiguousNames, candidate.signature, candidate.documentation,
  )

proc appendAutoImportCandidate*(
    stdlib: StdlibMap,
    candidate: SymbolCandidate,
    kind: CompletionKind,
    prefixKey: string,
    importedModules: openArray[string],
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
    ambiguousNames: var HashSet[string],
): bool =
  let module = canonicalModule(candidate.module)
  if module.len == 0 or candidate.name.len == 0 or candidate.name.startsWith("c_") or
      (stdlib != nil and isPrivateModule(module)):
    return true
  for imported in importedModules:
    if sameModule(module, imported):
      return true
  let key = identifierKey(candidate.name)
  if key.len == 0 or (prefixKey.len > 0 and not key.startsWith(prefixKey)) or
      key in ambiguousNames:
    return true
  if candidateByName.hasKey(key):
    let index = candidateByName[key]
    let existing = candidates[index]
    if existing.item.autoImportModule.len == 0 or
        sameModule(existing.item.autoImportModule, module):
      if existing.item.detail != candidate.signature:
        candidates[index].item.snippetText = ""
      return true
    candidates[index].key = ""
    candidateByName.del(key)
    ambiguousNames.incl(key)
    return true
  discard appendCompletionCandidate(
    candidate.name, kind, prefixKey, candidates, candidateByName, candidate.signature,
    candidate.documentation, module,
  )
  true

proc compareCompletion*(left, right: VisibleCompletion): int =
  result = cmp(left.key, right.key)
  if result != 0:
    return
  result = cmp(left.item.label, right.item.label)
  if result != 0:
    return
  result = cmp(left.declarationToken, right.declarationToken)

proc memberCompletionKind*(kind: SourceSymbolKind): CompletionKind {.inline.} =
  case kind
  of symbolConst:
    completionConstant
  of symbolMethod:
    completionMethod
  of symbolType:
    completionType
  of symbolProc, symbolFunc, symbolIterator, symbolMacro, symbolTemplate,
      symbolConverter:
    completionFunction
  of symbolVar, symbolLet:
    completionVariable

proc stdlibCompletionKind*(kind: string): CompletionKind {.inline.} =
  var known = false
  memberCompletionKind(sourceSymbolKind(kind, known))

proc boundedIdentifierDistance*(left, right: string, limit: uint8 = 2'u8): uint8 =
  let a = identifierKey(left)
  let b = identifierKey(right)
  if a == b:
    return 0
  let maximum = int(limit)
  if abs(a.len - b.len) > maximum:
    return uint8(maximum + 1)
  var matrix = newSeq[seq[int]](a.len + 1)
  for row in matrix.mitems:
    row = newSeq[int](b.len + 1)
  for column in 0 .. b.len:
    matrix[0][column] = column
  for row in 1 .. a.len:
    matrix[row][0] = row
  for row in 1 .. a.len:
    var rowMinimum = maximum + 1
    for column in 1 .. b.len:
      var value = min(
        matrix[row - 1][column] + 1,
        min(
          matrix[row][column - 1] + 1,
          matrix[row - 1][column - 1] + (if a[row - 1] == b[column - 1]: 0 else: 1),
        ),
      )
      if row > 1 and column > 1 and a[row - 1] == b[column - 2] and
          a[row - 2] == b[column - 1]:
        value = min(value, matrix[row - 2][column - 2] + 1)
      matrix[row][column] = value
      if value < rowMinimum:
        rowMinimum = value
    if rowMinimum > maximum:
      return uint8(maximum + 1)
  if matrix[a.len][b.len] > maximum:
    uint8(maximum + 1)
  else:
    uint8(matrix[a.len][b.len])

proc recoverCompletionItems*(
    items: openArray[CompletionItem], prefix: string
): seq[CompletionItem] =
  if prefix.len < 3:
    return
  let limit = if prefix.len >= 8: 2'u8 else: 1'u8
  var best = uint8(limit + 1)
  for item in items:
    let distance = boundedIdentifierDistance(prefix, item.label, limit)
    if distance > limit:
      continue
    if distance < best:
      result.setLen(0)
      best = distance
    if distance == best:
      var recovered = item
      recovered.recovered = true
      recovered.filterText = prefix
      recovered.sortText = $distance & ":" & identifierKey(item.label)
      result.add recovered
