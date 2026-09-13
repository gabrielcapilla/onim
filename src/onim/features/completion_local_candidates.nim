import std/[sets, strutils, tables]

import ./completion_candidates
import ./completion_models
import ../index/scopes
import ../index/scope_queries
import ../index/source_index
import ../index/symbols
import ../syntax/tokens

proc appendVisible*(
    index: SourceIndex,
    active: ScopeId,
    cursorToken: uint32,
    prefix: string,
    distances: Table[uint32, uint32],
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
    scopeNames: var seq[HashSet[string]],
): bool =
  for declaration in index.scopes.declarations:
    let nameIndex = int(declaration.nameToken)
    if nameIndex < 0 or nameIndex >= index.parsed.tokens.len:
      return false
    let token = index.parsed.tokens[nameIndex]
    if token.kind != tkIdentifier or not token.validIdentifier or token.isStropped or
        token.isNimKeyword:
      return false
    let distance = distances.getOrDefault(uint32(declaration.scope), high(uint32))
    if distance == high(uint32) or
        not index.scopes.isScopeAncestor(declaration.scope, active):
      continue
    let key = identifierKey(index.parsed.tokens, token)
    if key.len == 0:
      return false
    let scopeOrdinal = declaration.scope.scopeOrdinal
    if scopeOrdinal <= 0 or scopeOrdinal >= scopeNames.len:
      return false
    if key in scopeNames[scopeOrdinal]:
      return false
    scopeNames[scopeOrdinal].incl key
    if declaration.nameToken >= cursorToken:
      continue
    if not key.startsWith(identifierKey(prefix)):
      continue

    let item = CompletionItem(
      label: index.parsed.tokens.tokenText(token),
      kind:
        if declaration.kind == declarationConst:
          completionConstant
        else:
          completionVariable,
    )
    let visible = VisibleCompletion(
      item: item, key: key, distance: distance, declarationToken: declaration.nameToken
    )
    if not candidateByName.hasKey(key):
      candidateByName[key] = candidates.len
      candidates.add visible
    elif distance < candidates[candidateByName[key]].distance:
      candidates[candidateByName[key]] = visible
  true

proc appendVisibleModuleSymbols*(
    index: SourceIndex,
    cursorToken: uint32,
    prefix: string,
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
): bool =
  if index == nil:
    return false
  for symbol in index.symbols:
    if symbol.nameToken >= cursorToken:
      continue
    let tokenIndex = int(symbol.nameToken)
    if tokenIndex < 0 or tokenIndex >= index.parsed.tokens.len:
      return false
    let token = index.parsed.tokens[tokenIndex]
    if token.kind != tkIdentifier or not token.validIdentifier or token.isStropped or
        token.isNimKeyword:
      return false
    let key = identifierKey(index.parsed.tokens, token)
    if key.len == 0 or not key.startsWith(identifierKey(prefix)) or
        candidateByName.hasKey(key):
      continue
    candidateByName[key] = candidates.len
    candidates.add VisibleCompletion(
      item: CompletionItem(
        label: index.parsed.tokens.tokenText(token),
        kind: memberCompletionKind(symbol.kind),
      ),
      key: key,
      distance: high(uint32),
      declarationToken: symbol.nameToken,
    )
  true
