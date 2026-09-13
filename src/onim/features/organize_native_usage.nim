import std/sets

import ../index/bindings
import ../index/scopes
import ../index/scope_queries
import ../index/source_index
import ../index/surfaces
import ../index/surface_resolution
import ../session/module_catalog
import ../stdlib/map
import ../stdlib/map_resolution
import ../syntax/imports
import ../syntax/module_names
import ../syntax/tokens

type
  NativeBindingState* = enum
    nativeNoBinding
    nativeBound
    nativeUnknown

  NativeModuleUse* = enum
    nativeModuleUseNone
    nativeModuleUseFound
    nativeModuleUseUnknown

  NativeCandidateState* = enum
    nativeCandidateNone
    nativeCandidateResolved
    nativeCandidateAmbiguous
    nativeCandidateUnknown

  NativeCandidateSource* = enum
    nativeCandidateStdlibSource
    nativeCandidateProjectSource

proc hasLocalDefinition(info: SourceImports, name: string): bool =
  for definedName in info.localDefinitions:
    if sameIdentifier(definedName, name):
      return true

proc forBindingState(
    index: SourceIndex, name: string, tokenIndex: int
): NativeBindingState =
  if index == nil:
    return nativeUnknown
  let wanted = identifierKey(name)
  for forIndex, forToken in index.parsed.tokens:
    if not forToken.hasKeywordRole(roleForBinding):
      continue
    var cursor = forIndex + 1
    var separator = -1
    var foundName = false
    while cursor < index.parsed.tokens.len and
        index.parsed.tokens[cursor].line == forToken.line:
      let token = index.parsed.tokens[cursor]
      if index.parsed.tokens.tokenTextEquals(token, "in") or
          index.parsed.tokens.tokenTextEquals(token, "=") or
          index.parsed.tokens.tokenTextEquals(token, ":"):
        separator = cursor
        break
      if token.kind == tkIdentifier and not isNimKeyword(token) and
          identifierKey(index.parsed.tokens, token) == wanted:
        foundName = true
      inc cursor
    if not foundName:
      continue
    if tokenIndex <= forIndex or separator < 0 or tokenIndex <= separator:
      return nativeUnknown
    if index.parsed.tokens[tokenIndex].line == forToken.line:
      cursor = separator + 1
      while cursor < index.parsed.tokens.len and
          index.parsed.tokens[cursor].line == forToken.line and
          not index.parsed.tokens.tokenTextEquals(index.parsed.tokens[cursor], ":")
      :
        inc cursor
      if tokenIndex >= cursor:
        return nativeBound
      return nativeUnknown
    if index.parsed.tokens[tokenIndex].column > forToken.column:
      return nativeBound
    return nativeUnknown
  return nativeNoBinding

proc nativeBinding*(
    info: SourceImports, index: SourceIndex, name: string, tokenIndex: int
): NativeBindingState =
  if index == nil or tokenIndex < 0 or tokenIndex >= index.parsed.tokens.len:
    return nativeUnknown
  if index.bindingsReady:
    let binding = index.resolveBinding(uint32(tokenIndex))
    case binding.state
    of bindingResolved:
      return nativeBound
    of bindingAmbiguous:
      return nativeUnknown
    of bindingUnknown:
      discard
  var found = false
  for symbol in index.symbols:
    let symbolIndex = int(symbol.nameToken)
    if symbolIndex < 0 or symbolIndex >= index.parsed.tokens.len or
        identifierKey(index.parsed.tokens, index.parsed.tokens[symbolIndex]) !=
        identifierKey(name):
      continue
    found = true
    if symbolIndex >= tokenIndex:
      return nativeUnknown
    result = nativeBound

  let occurrenceScope = index.scopes.innermostScopeAt(uint32(tokenIndex))
  for declaration in index.scopes.declarations:
    let declarationIndex = int(declaration.nameToken)
    if declarationIndex < 0 or declarationIndex >= index.parsed.tokens.len or
        identifierKey(index.parsed.tokens, index.parsed.tokens[declarationIndex]) !=
        identifierKey(name) or
        not index.scopes.isScopeAncestor(declaration.scope, occurrenceScope):
      continue
    found = true
    if declarationIndex >= tokenIndex:
      return nativeUnknown
    result = nativeBound

  let forBinding = forBindingState(index, name, tokenIndex)
  if forBinding != nativeNoBinding:
    return forBinding
  if found:
    return
  if hasLocalDefinition(info, name):
    return nativeUnknown
  return nativeNoBinding

proc nativeNameUse*(
    info: SourceImports, index: SourceIndex, itemEnd: int, name: string
): NativeModuleUse =
  for occurrence in index.occurrences.identifiers:
    let tokenIndex = int(occurrence.token)
    if tokenIndex < 0 or tokenIndex >= index.parsed.tokens.len:
      continue
    let token = index.parsed.tokens[tokenIndex]
    if token.startOffset <= itemEnd or
        identifierKey(index.parsed.tokens, token) != identifierKey(name):
      continue
    if tokenIndex > 0 and
        index.parsed.tokens.tokenTextEquals(index.parsed.tokens[tokenIndex - 1], "."):
      continue
    case nativeBinding(info, index, name, tokenIndex)
    of nativeBound:
      discard
    of nativeUnknown:
      return nativeModuleUseUnknown
    of nativeNoBinding:
      if hasLocalDefinition(info, name):
        return nativeModuleUseUnknown
      return nativeModuleUseFound
  nativeModuleUseNone

proc nativeUnqualifiedUse(stdlib: StdlibMap, name, module: string): NativeModuleUse =
  let resolved = stdlib.resolveUniqueCandidate(name, "", -1)
  case resolved.state
  of candidateResolutionMissing:
    nativeModuleUseNone
  of candidateResolutionAmbiguous:
    for candidate in stdlib.candidatesFor(name, "", -1):
      if sameModule(candidate.module, module):
        return nativeModuleUseUnknown
    nativeModuleUseNone
  of candidateResolutionResolved:
    if sameModule(resolved.candidate.module, module):
      nativeModuleUseFound
    else:
      nativeModuleUseNone

proc nativeImplicitEquivalent*(
    stdlib: StdlibMap, name, qualifier: string, arity: int
): bool =
  let candidates = stdlib.candidatesFor(name, qualifier, arity)
  var implicitCount = 0
  for candidate in candidates:
    if stdlib.implicitModule(candidate.module):
      inc implicitCount
  if implicitCount == 0:
    return false
  for candidate in candidates:
    if stdlib.implicitModule(candidate.module):
      continue
    var equivalent = false
    for implicit in candidates:
      if stdlib.implicitModule(implicit.module) and candidate.kind == implicit.kind and
          candidate.arity == implicit.arity and candidate.signature == implicit.signature:
        equivalent = true
        break
    if not equivalent:
      return false
  true

proc projectModuleResolution*(
    project: SurfaceIndex, catalog: ModuleCatalog, owner, reference: string
): ModuleResolution =
  if project == nil:
    result.kind = moduleUnknown
    return
  if catalog != nil:
    return catalog.resolveModuleName(owner, reference)
  let module = project.moduleForReference(reference, owner)
  if module.len == 0:
    result.kind = if project.universeIsComplete: moduleMissing else: moduleUnknown
    return
  result.kind = moduleResolved
  result.module = module

proc nativeProjectModuleUse(
    project: SurfaceIndex, catalog: ModuleCatalog, owner, name, module: string
): NativeModuleUse =
  let resolved = projectModuleResolution(project, catalog, owner, module)
  case resolved.kind
  of moduleResolved:
    let binding = project.lookupInModule(resolved.module, name)
    case binding.kind
    of surfaceResolved: nativeModuleUseFound
    of surfaceUnresolved: nativeModuleUseNone
    of surfaceAmbiguous, surfaceUnknown: nativeModuleUseUnknown
  of moduleMissing:
    nativeModuleUseNone
  of moduleAmbiguous, moduleUnknown:
    nativeModuleUseUnknown

proc projectCandidate*(
    project: SurfaceIndex, catalog: ModuleCatalog, owner, name, qualifier: string
): tuple[state: NativeCandidateState, candidate: SymbolCandidate] =
  if project == nil:
    return
  let resolution = project.resolveSurfaceReference(catalog, name, qualifier, owner)
  case resolution.kind
  of surfaceResolved:
    let module = project.moduleForResolution(resolution)
    if module.len == 0:
      result.state = nativeCandidateUnknown
      return
    result.state = nativeCandidateResolved
    result.candidate = SymbolCandidate(
      module: module,
      name: name,
      kind: "",
      arity: -1,
      signature: "",
      priority: candidateDefault,
    )
  of surfaceUnresolved:
    result.state = nativeCandidateNone
  of surfaceAmbiguous:
    result.state = nativeCandidateAmbiguous
  of surfaceUnknown:
    result.state = nativeCandidateUnknown

proc nativeModuleUsed*(
    info: SourceImports,
    index: SourceIndex,
    item: ImportInfo,
    stdlib: StdlibMap,
    project: SurfaceIndex,
    catalog: ModuleCatalog,
    owner: string,
): NativeModuleUse =
  let module = canonicalModule(item.module)
  let qualifier =
    if item.alias.len > 0:
      item.alias
    else:
      moduleLeaf(item.module)
  for occurrence in index.occurrences.identifiers:
    let tokenIndex = int(occurrence.token)
    if tokenIndex < 0 or tokenIndex >= index.parsed.tokens.len:
      continue
    let token = index.parsed.tokens[tokenIndex]
    if token.startOffset <= item.endOffset:
      continue

    if tokenIndex >= 2 and
        index.parsed.tokens.tokenTextEquals(index.parsed.tokens[tokenIndex - 1], "."):
      let qualifierIndex = tokenIndex - 2
      let qualifierToken = index.parsed.tokens[qualifierIndex]
      if qualifierToken.kind == tkIdentifier and (
        qualifierIndex == 0 or
        not index.parsed.tokens.tokenTextEquals(
          index.parsed.tokens[qualifierIndex - 1], "."
        )
      ) and sameIdentifier(index.parsed.tokens.tokenText(qualifierToken), qualifier):
        let binding = nativeBinding(
          info, index, index.parsed.tokens.tokenText(qualifierToken), qualifierIndex
        )
        if binding == nativeUnknown:
          return nativeModuleUseUnknown
        if binding == nativeNoBinding:
          return nativeModuleUseFound
      continue

    if tokenIndex > 0 and
        index.parsed.tokens.tokenTextEquals(index.parsed.tokens[tokenIndex - 1], ".") or
        tokenIndex + 1 < index.parsed.tokens.len and
        index.parsed.tokens.tokenTextEquals(index.parsed.tokens[tokenIndex + 1], "."):
      continue
    let name = index.parsed.tokens.tokenText(token)
    let binding = nativeBinding(info, index, name, tokenIndex)
    if binding == nativeUnknown:
      return nativeModuleUseUnknown
    if binding == nativeNoBinding:
      let use =
        if stdlib.knownModule(module):
          nativeUnqualifiedUse(stdlib, name, module)
        else:
          nativeProjectModuleUse(project, catalog, owner, name, module)
      if use != nativeModuleUseNone:
        return use
  nativeModuleUseNone
