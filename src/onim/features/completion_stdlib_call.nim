import std/strutils
import std/sets
import std/tables

import ./completion_candidates
import ./completion_imports
import ./completion_models
import ./definition
import ./definition_models
import ./definition_visibility
import ../index/types
import ../index/type_local_models
import ../index/type_queries
import ../index/type_local_resolution
import ../stdlib/map
import ../stdlib/map_receivers
import ../stdlib/receiver_helpers
import ../session/workspace
import ../session/workspace_models
import ../syntax/imports
import ../syntax/module_names
import ../syntax/tokens

proc directNominalReturn*(stdlib: StdlibMap, module, name: string): string =
  if stdlib == nil:
    return
  let canonical = canonicalModule(module)
  if not canonical.startsWith("std/"):
    return
  let candidates = stdlib.candidatesFor(name, moduleBase(canonical), -1)
  if candidates.len != 1 or not callableCandidate(candidates[0].kind) or
      canonicalModule(candidates[0].module) != canonical:
    return
  let signature = candidates[0].signature
  let close = signature.rfind(')')
  if close < 0:
    return
  let colon = signature.find(':', close + 1)
  if colon < 0:
    return
  var first = colon + 1
  while first < signature.len and signature[first] in {' ', '\t', '\r', '\n'}:
    inc first
  var past = first
  while past < signature.len and signature[past] notin {' ', '\t', '\r', '\n', '{'}:
    inc past
  let candidate = signature[first ..< past]
  if plainNominalName(candidate):
    result = candidate

proc stdlibDirectCall*(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    stdlib: StdlibMap,
    declarationToken: uint32,
): tuple[module, typeName: string] =
  if workspace == nil or stdlib == nil or not stdlib.surfaceIsComplete or
      source.index == nil:
    return
  let local = source.index.types.localTypeAt(
    source.index.parsed.tokens, source.index.scopes, declarationToken
  )
  if local.form != localTypeFormCall or local.typeToken == InvalidTypeToken or
      local.typeToken >= uint32(source.index.parsed.tokens.len):
    return
  let nameToken = int(local.typeToken)
  let name = source.index.parsed.tokens.tokenText(source.index.parsed.tokens[nameToken])
  if source.index.moduleDeclarationShadows(nameToken) or
      not source.importedUseSupported(nameToken, name) or
      resolveDefinitionAtToken(workspace, source, nameToken).kind != definitionUnknown:
    return
  let qualified = local.firstToken != local.typeToken
  let qualifier =
    if qualified and local.firstToken < uint32(source.index.parsed.tokens.len):
      source.index.parsed.tokens.tokenText(
        source.index.parsed.tokens[int(local.firstToken)]
      )
    else:
      ""
  for item in source.index.parsed.imports:
    if item.form != importModule or item.alias.len > 0 or item.synthetic or
        source.index.parsed.conditionalImportDisposition(item) notin
        {importUnconditional, importConditionalActive} or item.excluded.len > 0:
      continue
    if qualified and not sameIdentifier(moduleLeaf(item.module), qualifier):
      continue
    let typeName = stdlib.directNominalReturn(item.module, name)
    if typeName.len == 0:
      continue
    let module = canonicalModule(item.module)
    if result.module.len > 0 and result.module != module:
      return ("", "")
    result = (module, typeName)

proc appendStdlibDirectCallMembers*(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    stdlib: StdlibMap,
    declarationToken: uint32,
    prefix: string,
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
): bool =
  let call = workspace.stdlibDirectCall(source, stdlib, declarationToken)
  if call.module.len == 0:
    return false
  for candidate in stdlib.directNominalMembers(call.module, call.typeName, prefix):
    discard appendCompletionCandidate(
      candidate.name,
      completionMethod,
      identifierKey(prefix),
      candidates,
      candidateByName,
    )
  candidates.len > 0
