import std/[sets, strutils]

import ../index/bindings
import ../index/occurrences
import ../index/source_index
import ../index/symbols
import ../index/surfaces
import ../index/surface_resolution
import ../stdlib/map
import ../stdlib/map_resolution
import ../session/module_catalog
import ../syntax/imports
import ../syntax/import_queries
import ../syntax/tokens

type
  NativeDiagnosticKind* = enum
    nativeMalformedIdentifier
    nativeUnclosedString
    nativeUnexpectedDelimiter
    nativeUnclosedDelimiter
    nativeUndeclaredIdentifier
    nativeMissingStdlibImport
    nativeMissingProjectImport

  NativeDiagnosticMode = enum
    nativeImportsOnly
    nativeImportsAndNames

  NativeDiagnostic* = object
    kind*: NativeDiagnosticKind
    startOffset*: int
    endOffset*: int
    name*: string
    module*: string

proc nativeSyntaxDiagnostics*(index: SourceIndex): seq[NativeDiagnostic]

proc localName(info: SourceImports, name: string): bool =
  for definedName in info.localDefinitions:
    if sameIdentifier(definedName, name):
      return true

proc importedName(info: SourceImports, name: string): bool =
  for item in info.imports:
    if item.synthetic or item.conditional:
      continue
    if item.form != fromModule:
      continue
    for imported in item.importedSymbols:
      if sameIdentifier(imported.name, name):
        return true

proc stdlibModule(stdlib: StdlibMap, module: string): bool =
  if stdlib == nil:
    return false
  for known in stdlib.modules:
    if sameModule(known, module):
      return true

proc providesUnqualified(
    info: SourceImports,
    stdlib: StdlibMap,
    project: SurfaceIndex,
    catalog: ModuleCatalog,
    owner, name: string,
): bool =
  if localName(info, name) or importedName(info, name):
    return true
  for item in info.imports:
    if item.synthetic or item.conditional or item.form != importModule or
        item.excluded.len > 0:
      continue
    if stdlibModule(stdlib, item.module):
      for candidate in stdlib.candidatesFor(name, "", -1):
        if sameModule(candidate.module, item.module):
          return true
    elif project != nil:
      let module =
        if catalog != nil:
          catalog.resolveModuleName(owner, item.module)
        else:
          ModuleResolution(
            kind:
              if project.moduleForReference(item.module, owner).len > 0:
                moduleResolved
              else:
                moduleMissing,
            module: project.moduleForReference(item.module, owner),
          )
      if module.kind != moduleResolved:
        continue
      let resolution = project.lookupInModule(module.module, name)
      if resolution.kind == surfaceResolved:
        return true

proc nativeNamesSafe(
    index: SourceIndex,
    stdlib: StdlibMap,
    project: SurfaceIndex,
    catalog: ModuleCatalog,
    owner: string,
): bool =
  if index == nil or stdlib == nil or not stdlib.surfaceIsComplete or
      not index.nativeIndexSafe():
    return false
  for item in index.parsed.imports:
    if stdlibModule(stdlib, item.module):
      continue
    if project == nil or not project.universeIsComplete:
      return false
    if catalog != nil:
      if catalog.resolveModuleName(owner, item.module).kind != moduleResolved:
        return false
    elif project.moduleForReference(item.module, owner).len == 0:
      return false
  true

proc addMissingDiagnostic(
    result: var seq[NativeDiagnostic],
    seen: var HashSet[string],
    token: Token,
    name, module: string,
    kind: NativeDiagnosticKind,
) =
  let key = identifierKey(name) & "\x00" & module
  if key in seen:
    return
  seen.incl key
  result.add NativeDiagnostic(
    kind: kind,
    startOffset: token.startOffset,
    endOffset: token.endOffset,
    module: module,
  )

proc addUndeclaredDiagnostic(
    diagnostics: var seq[NativeDiagnostic],
    seen: var HashSet[string],
    tokens: TokenStore,
    token: Token,
): bool =
  let name = tokens.tokenText(token)
  let key = identifierKey(tokens, token)
  if key.len == 0 or key in seen:
    return false
  seen.incl key
  diagnostics.add NativeDiagnostic(
    kind: nativeUndeclaredIdentifier,
    startOffset: token.startOffset,
    endOffset: token.endOffset,
    name: name,
  )
  true

proc nativeMissingDiagnostics(
    index: SourceIndex,
    stdlib: StdlibMap,
    project: SurfaceIndex,
    catalog: ModuleCatalog,
    owner: string,
    mode: NativeDiagnosticMode,
): seq[NativeDiagnostic] =
  if not nativeNamesSafe(index, stdlib, project, catalog, owner):
    return
  var seen = initHashSet[string]()
  for occurrence in index.occurrences.identifiers:
    let tokenIndex = int(occurrence.token)
    if tokenIndex < 0 or tokenIndex >= index.parsed.tokens.len or
        occurrence.roles.contains(occurrenceMember) or
        occurrence.roles.contains(occurrenceQualifier):
      continue
    let token = index.parsed.tokens[tokenIndex]
    let tokenName = index.parsed.tokens.tokenText(token)
    let binding = index.resolveBinding(occurrence.token)
    if binding.state != bindingUnknown or
        index.implicitNameKind(occurrence.token) != implicitNone:
      continue
    if providesUnqualified(index.parsed, stdlib, project, catalog, owner, tokenName):
      continue
    let resolved = stdlib.resolveUniqueCandidate(tokenName, "", -1)
    let projectResolved = project.resolveSurfaceReference(catalog, tokenName, "", owner)
    if project != nil and projectResolved.candidates.len > 0 and
        projectResolved.kind in {surfaceUnknown, surfaceAmbiguous}:
      continue
    case resolved.state
    of candidateResolutionResolved:
      if stdlib.implicitModule(resolved.candidate.module):
        continue
      let module = canonicalModule(resolved.candidate.module)
      if not module.startsWith("std/") or module notin stdlib.modules:
        continue
      let projectModule = project.moduleForResolution(projectResolved)
      if projectModule.len > 0 and not sameModule(projectModule, module):
        continue
      addMissingDiagnostic(
        result, seen, token, tokenName, module, nativeMissingStdlibImport
      )
    of candidateResolutionMissing:
      let module = project.moduleForResolution(projectResolved)
      if module.len > 0:
        addMissingDiagnostic(
          result, seen, token, tokenName, module, nativeMissingProjectImport
        )
    of candidateResolutionAmbiguous:
      discard
    if mode == nativeImportsAndNames and resolved.state == candidateResolutionMissing and
        projectResolved.kind == surfaceUnknown:
      discard addUndeclaredDiagnostic(result, seen, index.parsed.tokens, token)

  for qualified in index.occurrences.qualified:
    let qualifierIndex = int(qualified.qualifierToken)
    let memberIndex = int(qualified.memberToken)
    if qualifierIndex < 0 or memberIndex < 0 or memberIndex >= index.parsed.tokens.len or
        qualifierIndex >= index.parsed.tokens.len or
        qualifierIndex > 0 and
        index.parsed.tokens.tokenTextEquals(
          index.parsed.tokens[qualifierIndex - 1], "."
        ):
      continue
    let qualifier = index.parsed.tokens[qualifierIndex]
    let member = index.parsed.tokens[memberIndex]
    let qualifierName = index.parsed.tokens.tokenText(qualifier)
    let memberName = index.parsed.tokens.tokenText(member)
    let binding = index.resolveBinding(qualified.qualifierToken)
    if binding.state != bindingUnknown or localName(index.parsed, qualifierName) or
        index.parsed.providesQualifier(qualifierName):
      continue
    let resolved = stdlib.resolveUniqueCandidate(memberName, qualifierName, -1)
    let projectResolved =
      project.resolveSurfaceReference(catalog, memberName, qualifierName, owner)
    if project != nil and projectResolved.kind in {surfaceUnknown, surfaceAmbiguous}:
      continue
    case resolved.state
    of candidateResolutionResolved:
      if stdlib.implicitModule(resolved.candidate.module):
        continue
      let module = canonicalModule(resolved.candidate.module)
      if not module.startsWith("std/") or module notin stdlib.modules:
        continue
      let projectModule = project.moduleForResolution(projectResolved)
      if projectModule.len > 0 and not sameModule(projectModule, module):
        continue
      addMissingDiagnostic(
        result, seen, qualifier, memberName, module, nativeMissingStdlibImport
      )
    of candidateResolutionMissing:
      let module = project.moduleForResolution(projectResolved)
      if module.len > 0:
        addMissingDiagnostic(
          result, seen, qualifier, memberName, module, nativeMissingProjectImport
        )
    of candidateResolutionAmbiguous:
      discard

proc nativeMissingStdlibDiagnostics*(
    index: SourceIndex, stdlib: StdlibMap
): seq[NativeDiagnostic] =
  nativeMissingDiagnostics(index, stdlib, nil, nil, "", nativeImportsOnly)

proc nativeDiagnostics*(
    index: SourceIndex,
    stdlib: StdlibMap,
    project: SurfaceIndex = nil,
    owner: string = "",
    catalog: ModuleCatalog = nil,
): seq[NativeDiagnostic] =
  result = nativeSyntaxDiagnostics(index)
  result.add nativeMissingDiagnostics(
    index, stdlib, project, catalog, owner, nativeImportsAndNames
  )

proc nativeSyntaxDiagnostics*(index: SourceIndex): seq[NativeDiagnostic] =
  if index == nil:
    return

  for issue in lexicalIssues(index.parsed.tokens):
    let tokenIndex = int(issue.tokenIndex)
    if tokenIndex < 0 or tokenIndex >= index.parsed.tokens.len:
      continue
    let token = index.parsed.tokens[tokenIndex]
    let kind =
      case issue.kind
      of lexicalMalformedIdentifier: nativeMalformedIdentifier
      of lexicalUnclosedString: nativeUnclosedString
      of lexicalUnexpectedDelimiter: nativeUnexpectedDelimiter
      of lexicalUnclosedDelimiter: nativeUnclosedDelimiter
    result.add NativeDiagnostic(
      kind: kind, startOffset: token.startOffset, endOffset: token.endOffset
    )
