import ../syntax/imports
import ../syntax/lexer
import ./occurrences
import ./scopes
import ./source_index
import ./symbols

type
  BindingState* = enum
    bindingUnknown
    bindingResolved
    bindingAmbiguous

  BindingResolution* = object
    state*: BindingState
    declarationToken*: uint32

  ImplicitNameKind* = enum
    implicitNone
    implicitResult

const InvalidBindingToken* = high(uint32)

proc resolved(token: uint32): BindingResolution {.inline.} =
  BindingResolution(state: bindingResolved, declarationToken: token)

proc ambiguous(): BindingResolution {.inline.} =
  BindingResolution(state: bindingAmbiguous, declarationToken: InvalidBindingToken)

proc localScope(index: ScopeIndex, scope: ScopeId): bool {.inline.} =
  let ordinal = int(uint32(scope)) - 1
  ordinal >= 0 and ordinal < index.scopes.len and
    index.scopes[ordinal].kind in {scopeRoutine, scopeBlock}

proc declarationName(
    index: SourceIndex, declaration: LexicalDeclaration
): string {.inline.} =
  if declaration.nameToken < uint32(index.parsed.tokens.len):
    return identifierKey(index.parsed.tokens[int(declaration.nameToken)].text)

proc declarationIndexAt(index: SourceIndex, token: uint32): int =
  for declarationIndex, declaration in index.scopes.declarations:
    if declaration.nameToken == token:
      return declarationIndex
  -1

proc hasDuplicateDeclaration(index: SourceIndex, declarationIndex: int): bool =
  let declaration = index.scopes.declarations[declarationIndex]
  let wanted = index.declarationName(declaration)
  if wanted.len == 0:
    return true
  for candidateIndex, candidate in index.scopes.declarations:
    if candidateIndex != declarationIndex and candidate.scope == declaration.scope and
        candidate.nameToken < uint32(index.parsed.tokens.len) and
        index.declarationName(candidate) == wanted:
      return true
  false

proc bindingsReady*(index: SourceIndex): bool =
  if index == nil or not index.scopes.isComplete:
    return false
  for reason in index.occurrences.uncertainty:
    case reason
    of uncertaintyNestedScope, uncertaintyDeclarationOrder:
      discard
    of uncertaintyUnsupportedSyntax:
      for tokenIndex, token in index.parsed.tokens:
        if token.kind == tkPunctuation and operatorPunctuation(token.text):
          continue
        if token.text == "{" and tokenIndex + 1 < index.parsed.tokens.len and
            index.parsed.tokens[tokenIndex + 1].text == ".":
          return false
    else:
      return false
  true

proc resolveBinding*(index: SourceIndex, tokenIndex: uint32): BindingResolution =
  if not index.bindingsReady or tokenIndex >= uint32(index.parsed.tokens.len):
    return
  let token = index.parsed.tokens[int(tokenIndex)]
  if token.kind != tkIdentifier or not validIdentifier(token) or isNimKeyword(token) or
      index.parsed.tokenInsideImport(token):
    return
  let declarationIndex = index.declarationIndexAt(tokenIndex)
  if declarationIndex >= 0:
    if index.hasDuplicateDeclaration(declarationIndex):
      return ambiguous()
    return resolved(tokenIndex)

  let wanted = identifierKey(token.text)
  if wanted.len == 0:
    return
  var scope = index.scopes.innermostScopeAt(tokenIndex)
  if not index.scopes.localScope(scope):
    return
  while index.scopes.localScope(scope):
    var found = InvalidBindingToken
    for declaration in index.scopes.declarations:
      if declaration.scope != scope or declaration.nameToken >= tokenIndex or
          index.declarationName(declaration) != wanted:
        continue
      if found != InvalidBindingToken:
        return ambiguous()
      found = declaration.nameToken
    if found != InvalidBindingToken:
      return resolved(found)
    scope = index.scopes.parentScope(scope)

proc implicitNameKind*(index: SourceIndex, tokenIndex: uint32): ImplicitNameKind =
  if index == nil or tokenIndex >= uint32(index.parsed.tokens.len):
    return implicitNone
  let token = index.parsed.tokens[int(tokenIndex)]
  if token.kind != tkIdentifier or isStropped(token) or
      identifierKey(token.text) != "result":
    return implicitNone
  var scope = index.scopes.innermostScopeAt(tokenIndex)
  while index.scopes.localScope(scope):
    let ordinal = int(uint32(scope)) - 1
    if index.scopes.scopes[ordinal].kind == scopeRoutine:
      return implicitResult
    scope = index.scopes.parentScope(scope)
  implicitNone

proc bindingRegionContains*(
    index: SourceIndex, declarationToken, useToken: uint32
): bool =
  if index == nil or declarationToken >= uint32(index.parsed.tokens.len) or
      useToken >= uint32(index.parsed.tokens.len):
    return false
  let declarationIndex = index.declarationIndexAt(declarationToken)
  if declarationIndex < 0:
    return false
  let declarationScope = index.scopes.declarations[declarationIndex].scope
  var useScope = index.scopes.innermostScopeAt(useToken)
  while index.scopes.localScope(useScope):
    if useScope == declarationScope:
      return true
    useScope = index.scopes.parentScope(useScope)
  false
