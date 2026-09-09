import std/[sets, strutils, tables]

import ../index/symbols
import ../syntax/tokens
import ./completion_models

type VisibleCompletion* = object
  item*: CompletionItem
  key*: string
  distance*: uint32
  declarationToken*: uint32

proc appendCompletionCandidate*(
    name: string,
    kind: CompletionKind,
    prefixKey: string,
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
): bool =
  let key = identifierKey(name)
  if key.len == 0 or (prefixKey.len > 0 and not key.startsWith(prefixKey)):
    return true
  let visible = VisibleCompletion(
    item: CompletionItem(label: name, kind: kind),
    key: key,
    declarationToken: high(uint32),
  )
  if not candidateByName.hasKey(key):
    candidateByName[key] = candidates.len
    candidates.add visible
  elif ord(visible.item.kind) < ord(candidates[candidateByName[key]].item.kind):
    candidates[candidateByName[key]] = visible
  true

proc appendImportedCandidate*(
    name, providerKey: string,
    kind: CompletionKind,
    prefixKey: string,
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
    importedProviders: var Table[string, string],
    ambiguousNames: var HashSet[string],
): bool =
  let key = identifierKey(name)
  if key.len == 0 or (prefixKey.len > 0 and not key.startsWith(prefixKey)):
    return true
  if key in ambiguousNames:
    return true
  if candidateByName.hasKey(key):
    if not importedProviders.hasKey(key):
      return true
    if importedProviders[key] == providerKey:
      return true
    candidates[candidateByName[key]].key = ""
    candidateByName.del(key)
    importedProviders.del(key)
    ambiguousNames.incl(key)
    return true
  discard appendCompletionCandidate(name, kind, prefixKey, candidates, candidateByName)
  if candidateByName.hasKey(key):
    importedProviders[key] = providerKey
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
