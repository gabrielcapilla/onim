import std/strutils
import std/sets

import ./definition
import ./definition_models
import ./definition_visibility
import ../index/type_kinds
import ../index/type_local_models
import ../index/type_states
import ../index/types
import ../stdlib/map
import ../session/workspace
import ../session/workspace_models
import ../syntax/imports
import ../syntax/module_names
import ../syntax/tokens

proc stdlibNominalTypeModule*(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    stdlib: StdlibMap,
    localType: LocalTypeResolution,
): string =
  if workspace == nil or stdlib == nil or not stdlib.surfaceIsComplete or
      source.index == nil or localType.info.state != typeStateResolved or
      localType.info.form != localTypeFormAnnotation or localType.info.kind != typeNamed or
      localType.info.typeToken >= uint32(source.index.parsed.tokens.len):
    return
  let typeToken = int(localType.info.typeToken)
  let typeName =
    source.index.parsed.tokens.tokenText(source.index.parsed.tokens[typeToken])
  if typeName.len == 0 or not source.importedUseSupported(typeToken, typeName) or
      resolveDefinitionAtToken(workspace, source, typeToken).kind != definitionUnknown:
    return

  var provider = ""
  for item in source.index.parsed.imports:
    if item.form != importModule or item.alias.len > 0 or item.synthetic or
        source.index.parsed.conditionalImportDisposition(item) notin
        {importUnconditional, importConditionalActive} or item.excluded.len > 0:
      continue
    let module = canonicalModule(item.module)
    if not module.startsWith("std/"):
      continue
    var matches = 0
    for candidate in stdlib.candidatesFor(typeName, ""):
      if sameModule(candidate.module, module) and
          (candidate.kind == "skType" or candidate.kind == "type"):
        inc matches
    if matches != 1:
      if matches > 1:
        return
      continue
    if provider.len > 0 and provider != module:
      return
    provider = module
  provider
