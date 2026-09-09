import std/strutils

import ../index/source_index
import ../session/ids
import ../session/workspace
import ../session/workspace_models
import ../syntax/imports
import ../syntax/import_queries
import ../syntax/tokens
import ./definition_models
import ./definition_resolution_results
import ./definition_routine_filter
import ./definition_source_queries
import ./definition_symbol_target
import ./definition_visibility

proc resolveQualified*(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    qualifier, member: string,
    memberToken = -1,
): DefinitionResolution =
  let localQualifier = symbolMatches(source.index, qualifier)
  if localQualifier.len > 0:
    return unknownResolution()

  var targets: seq[DefinitionTarget] = @[]
  var matched = false
  var unresolved = false
  for item in source.index.parsed.imports:
    if item.form != importModule or item.synthetic or
        not item.qualifierMatches(qualifier):
      continue
    matched = true
    if item.conditional or hasExcept(source.index.parsed, item):
      return unknownResolution()
    let moduleId = workspace.resolveModule(source.fileId, item.module)
    if not moduleId.valid:
      if item.module.startsWith("std/"):
        return unknownResolution()
      unresolved = true
      continue
    let view = workspace.indexViewForFile(moduleId)
    if not view.valid or view.index == nil:
      unresolved = true
      continue
    let matches = filterRoutineMatches(
      view.index,
      symbolMatches(view.index, member, exportedOnly = true),
      source.index.parsed.tokens,
      memberToken,
    )
    if matches.len > 1:
      return unknownResolution(definitionAmbiguous)
    for symbolIndex in matches:
      let candidate = targetFor(source, view, symbolIndex)
      if candidate.kind != definitionResolved:
        return candidate
      targets.addTarget(candidate.target)
  if not matched:
    return unknownResolution()
  finishTargets(targets, unresolved)

proc resolveFrom*(
    workspace: Workspace, source: WorkspaceSnapshot, name: string
): DefinitionResolution =
  var targets: seq[DefinitionTarget] = @[]
  var matched = false
  var unresolved = false
  for item in source.index.parsed.imports:
    if item.form != fromModule or item.synthetic:
      continue
    for imported in item.importedSymbols:
      if not sameIdentifier(imported.name, name):
        continue
      matched = true
      let binding =
        fromImportBinding(source.index.parsed.tokens, source.text, item, name)
      if binding.kind notin {fromImportPlain, fromImportAlias}:
        return unknownResolution()
      let moduleId = workspace.resolveModule(source.fileId, item.module)
      if not moduleId.valid:
        if item.module.startsWith("std/"):
          return unknownResolution()
        unresolved = true
        continue
      let view = workspace.indexViewForFile(moduleId)
      if not view.valid or view.index == nil:
        unresolved = true
        continue
      let matches = symbolMatches(view.index, binding.providerName, exportedOnly = true)
      if matches.len > 1:
        return unknownResolution(definitionAmbiguous)
      for symbolIndex in matches:
        let candidate = targetFor(source, view, symbolIndex)
        if candidate.kind != definitionResolved:
          return candidate
        targets.addTarget(candidate.target)
  if not matched:
    return unknownResolution()
  finishTargets(targets, unresolved)
