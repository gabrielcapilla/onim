import std/strutils
import std/sets

import ../index/source_index
import ../index/surfaces
import ../session/module_catalog
import ../stdlib/map
import ../stdlib/map_resolution
import ../syntax/imports
import ../syntax/import_queries
import ../syntax/module_names
import ../syntax/tokens
import ./organize_native_usage
import ./organize_planning
import ./organize_queries

proc nativeProvidesName(info: SourceImports, name: string): bool =
  for item in info.imports:
    if item.synthetic or
        info.conditionalImportDisposition(item) notin
        {importUnconditional, importConditionalActive} or item.form != fromModule:
      continue
    for imported in item.importedSymbols:
      if sameIdentifier(imported.name, name):
        return true

proc nativeImportAdditions*(
    source: string,
    info: SourceImports,
    index: SourceIndex,
    stdlib: StdlibMap,
    project: SurfaceIndex,
    catalog: ModuleCatalog,
    owner: string,
): tuple[safe: bool, candidates: seq[PlannedImport]] =
  result.safe = true
  for occurrence in index.occurrences.identifiers:
    let tokenIndex = int(occurrence.token)
    if tokenIndex < 0 or tokenIndex >= index.parsed.tokens.len:
      continue
    let token = index.parsed.tokens[tokenIndex]

    var name = index.parsed.tokens.tokenText(token)
    var qualifier = ""
    if tokenIndex >= 2 and
        index.parsed.tokens.tokenTextEquals(index.parsed.tokens[tokenIndex - 1], "."):
      let qualifierIndex = tokenIndex - 2
      if qualifierIndex < 0 or index.parsed.tokens[qualifierIndex].kind != tkIdentifier or
      (
        qualifierIndex > 0 and
        index.parsed.tokens.tokenTextEquals(
          index.parsed.tokens[qualifierIndex - 1], "."
        )
      ):
        continue
      qualifier = index.parsed.tokens.tokenText(index.parsed.tokens[qualifierIndex])
      let binding = nativeBinding(info, index, qualifier, qualifierIndex)
      if binding == nativeBound:
        continue
      if binding == nativeUnknown:
        result.safe = false
        return
    elif tokenIndex > 0 and
        index.parsed.tokens.tokenTextEquals(index.parsed.tokens[tokenIndex - 1], ".") or
        tokenIndex + 1 < index.parsed.tokens.len and
        index.parsed.tokens.tokenTextEquals(index.parsed.tokens[tokenIndex + 1], "."):
      continue

    let arity = callArity(info, source, tokenIndex)
    let resolved = stdlib.resolveUniqueCandidate(name, qualifier, arity)
    if qualifier.len == 0:
      let binding = nativeBinding(info, index, name, tokenIndex)
      if binding == nativeBound:
        continue
      if binding == nativeUnknown:
        result.safe = false
        return
    var projectResult: tuple[state: NativeCandidateState, candidate: SymbolCandidate]
    if project == nil or project.universeIsComplete():
      projectResult = projectCandidate(project, catalog, owner, name, qualifier)
    elif stdlib.nativeImplicitEquivalent(name, qualifier, arity):
      projectResult.state = nativeCandidateNone
    else:
      projectResult.state = nativeCandidateUnknown
    var candidate: SymbolCandidate
    var candidateSource = nativeCandidateStdlibSource
    case projectResult.state
    of nativeCandidateResolved:
      if resolved.state != candidateResolutionMissing:
        result.safe = false
        return
      candidate = projectResult.candidate
      candidateSource = nativeCandidateProjectSource
    of nativeCandidateNone:
      case resolved.state
      of candidateResolutionMissing:
        continue
      of candidateResolutionAmbiguous:
        if stdlib.nativeImplicitEquivalent(name, qualifier, arity):
          continue
        result.safe = false
        return
      of candidateResolutionResolved:
        candidate = resolved.candidate
    of nativeCandidateAmbiguous, nativeCandidateUnknown:
      result.safe = false
      return

    case candidateSource
    of nativeCandidateStdlibSource:
      if stdlib.implicitModule(candidate.module):
        continue
      if candidate.module.len == 0 or
          not canonicalModule(candidate.module).startsWith("std/") or
          canonicalModule(candidate.module) notin stdlib.modules:
        result.safe = false
        return
    of nativeCandidateProjectSource:
      if project == nil or not project.universeIsComplete:
        result.safe = false
        return
      let module = projectModuleResolution(project, catalog, owner, candidate.module)
      if module.kind != moduleResolved or not sameModule(
        module.module, candidate.module
      ):
        result.safe = false
        return
      if owner.len > 0 and sameModule(candidate.module, owner):
        continue
    let existing = findExistingModule(info, candidate.module)
    if nativeProvidesName(info, name) or
        (qualifier.len > 0 and info.providesQualifier(qualifier)) or existing.plain >= 0 or
        existing.aliased >= 0:
      continue
    addUniqueModule(result.candidates, candidate, false)
