import std/[algorithm, sets, strutils, tables]

import ./definition
import ./completion_models
import ./completion_candidates
import ./completion_condition_names
import ./completion_import_candidates
import ./completion_object_fields
import ./completion_stdlib_nominal
import ./definition_models
import ./completion_context
import ./completion_enum_members
import ./definition_enum_receiver
import ./completion_imports
import ./completion_local_candidates
import ./completion_module_candidates
import ./completion_primitive_types
import ./completion_stdlib_call
import ./completion_ufcs
import ../stdlib/map_receivers
import ./completion_stdlib_module
import ./definition_visibility
import ../index/bindings
import ../index/occurrences
import ../index/scopes
import ../index/scope_queries
import ../index/source_index
import ../index/symbols
import ../index/surfaces
import ../index/surface_project_input
import ../index/surface_resolution
import ../index/type_ids
import ../index/type_object_queries
import ../index/type_expression_syntax
import ../index/type_queries
import ../index/type_states
import ../index/types
import ../stdlib/map
import ../session/ids
import ../session/module_catalog
import ../session/workspace
import ../session/workspace_models
import ../syntax/imports
import ../syntax/import_queries
import ../syntax/module_names
import ../syntax/tokens

proc appendUnqualifiedImports(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    stdlib: StdlibMap,
    prefixKey: string,
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
): bool =
  if workspace == nil or not source.valid or source.index == nil or
      not source.index.bindingsReady or not source.index.nativeIndexSafe():
    return false
  var importedProviders = initTable[string, string]()
  var ambiguousNames = initHashSet[string]()
  let catalog = workspace.moduleCatalog()
  let owner =
    if catalog != nil:
      catalog.moduleForPath(source.path)
    else:
      ""
  for item in source.index.parsed.imports:
    if item.synthetic or
        source.index.parsed.conditionalImportDisposition(item) notin
        {importUnconditional, importConditionalActive}:
      continue
    if item.form == importModule and item.alias.len > 0:
      continue
    var projectResolved = false
    if catalog != nil and catalog.complete:
      let project = catalog.resolveModuleName(owner, item.module)
      case project.kind
      of moduleResolved:
        projectResolved = true
        discard appendProjectImport(
          workspace, source, item, owner, catalog, prefixKey, candidates,
          candidateByName, importedProviders, ambiguousNames,
        )
      of moduleAmbiguous, moduleUnknown:
        projectResolved = true
      of moduleMissing:
        discard
    if not projectResolved:
      discard appendStdlibImport(
        stdlib, source, item, prefixKey, candidates, candidateByName, importedProviders,
        ambiguousNames,
      )
  true

proc mergeImportedCompletions(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    stdlib: StdlibMap,
    result: var CompletionResult,
) =
  if result.state != completionAvailable:
    return
  var candidates = newSeqOfCap[VisibleCompletion](result.items.len)
  var candidateByName = initTable[string, int]()
  for item in result.items:
    let key = identifierKey(item.label)
    if key.len == 0:
      continue
    candidateByName[key] = candidates.len
    candidates.add VisibleCompletion(
      item: item, key: key, declarationToken: high(uint32)
    )
  discard appendUnqualifiedImports(
    workspace,
    source,
    stdlib,
    identifierKey(
      if result.replaceEnd > result.replaceStart:
        source.text[result.replaceStart ..< result.replaceEnd]
      else:
        ""
    ),
    candidates,
    candidateByName,
  )
  candidates.sort(compareCompletion)
  result.items = newSeqOfCap[CompletionItem](candidates.len)
  for candidate in candidates:
    if candidate.key.len > 0:
      result.items.add candidate.item

proc completeModuleImportedNames(
    workspace: Workspace, source: WorkspaceSnapshot, byteOffset: int, stdlib: StdlibMap
): CompletionResult =
  if workspace == nil or not source.valid or source.index == nil or
      source.path.toLowerAscii.endsWith(".nimble") or
      source.path.toLowerAscii.endsWith(".cfg") or byteOffset < 0 or
      byteOffset > source.text.len or not source.index.bindingsReady or
      source.index.unsupportedStructure or not source.index.nativeIndexSafe():
    return
  let tokenIndex = source.index.prefixToken(byteOffset)
  if tokenIndex < 0 or not source.index.completionContext(tokenIndex) or
      source.index.implicitNameKind(uint32(tokenIndex)) != implicitNone:
    return
  let active = source.index.scopes.innermostScopeAt(uint32(tokenIndex))
  let ordinal = active.scopeOrdinal
  if ordinal < 0 or ordinal >= source.index.scopes.scopes.len or
      source.index.scopes.scopes[ordinal].kind != scopeModule:
    return

  var candidates: seq[VisibleCompletion] = @[]
  var candidateByName = initTable[string, int]()
  for symbol in source.index.symbols:
    if symbol.nameToken >= uint32(source.index.parsed.tokens.len):
      continue
    let name = source.index.parsed.tokens.tokenText(
      source.index.parsed.tokens[int(symbol.nameToken)]
    )
    let key = identifierKey(name)
    if key.len == 0 or candidateByName.hasKey(key):
      continue
    candidateByName[key] = candidates.len
    candidates.add VisibleCompletion(key: "", declarationToken: symbol.nameToken)
  let prefix =
    source.index.parsed.tokens.tokenText(source.index.parsed.tokens[tokenIndex])
  discard appendUnqualifiedImports(
    workspace, source, stdlib, identifierKey(prefix), candidates, candidateByName
  )
  candidates.sort(compareCompletion)
  result.state = completionAvailable
  result.replaceStart = source.index.parsed.tokens[tokenIndex].startOffset
  result.replaceEnd = byteOffset
  result.items = newSeqOfCap[CompletionItem](candidates.len)
  for candidate in candidates:
    if candidate.key.len > 0:
      result.items.add candidate.item

proc completeLocalMembers(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    stdlib: StdlibMap,
    context: MemberContext,
    declarationToken: uint32,
): CompletionResult =
  if workspace == nil or not source.valid or source.index == nil or
      not source.index.bindingsReady or not source.index.nativeIndexSafe():
    return
  let indexToken =
    if context.qualifierKind == qualifierIndexedSequence:
      uint32(context.indexToken)
    else:
      InvalidTypeToken
  let localType = workspace.resolveReceiverType(source, declarationToken, indexToken)
  var candidates: seq[VisibleCompletion] = @[]
  var candidateByName = initTable[string, int]()
  var stdlibNominal = false
  if localType.info.state != typeStateResolved or not localType.info.typeId.valid:
    if not appendStdlibDirectCallMembers(
      workspace, source, stdlib, declarationToken, context.prefix, candidates,
      candidateByName,
    ):
      return
  else:
    let receiver =
      resolveObjectReceiver(workspace, source, declarationToken, indexToken)
    if receiver.resolved:
      let visibility = if receiver.exportedOnly: fieldsExported else: fieldsAll
      let objectType =
        if receiver.fieldSource == objectFieldsLocalTuple:
          receiver.provider.types.localTupleObjects[int(receiver.objectOrdinal)]
        else:
          receiver.provider.types.objects[int(receiver.objectOrdinal)]
      let fields =
        if receiver.fieldSource == objectFieldsLocalTuple:
          receiver.provider.types.localTupleFields
        else:
          receiver.provider.types.fields
      if not appendObjectFields(
        receiver.provider,
        fields,
        objectType,
        identifierKey(context.prefix),
        visibility,
        candidates,
        candidateByName,
      ):
        return
    stdlibNominal = appendStdlibNominalMembers(
      workspace, source, stdlib, localType, context.prefix, candidates, candidateByName
    )
    let implicitFile = appendImplicitFileMembers(
      workspace,
      source,
      stdlib,
      localType.info,
      identifierKey(context.prefix),
      candidates,
      candidateByName,
    )
    if not appendUfcsMembers(
      workspace,
      source,
      localType,
      identifierKey(context.prefix),
      candidates,
      candidateByName,
    ) and not implicitFile and not stdlibNominal:
      return
  if candidates.len == 0:
    return
  candidates.sort(compareCompletion)
  result.state = completionAvailable
  result.replaceStart = context.replaceStart
  result.replaceEnd = context.replaceEnd
  result.items = newSeqOfCap[CompletionItem](candidates.len)
  for candidate in candidates:
    result.items.add candidate.item

proc completeLocals*(source: WorkspaceSnapshot, byteOffset: int): CompletionResult =
  if not source.valid or source.index == nil or
      source.path.toLowerAscii.endsWith(".nimble") or
      source.path.toLowerAscii.endsWith(".cfg") or byteOffset < 0 or
      byteOffset > source.text.len or not source.index.bindingsReady or
      source.index.unsupportedStructure:
    return
  let tokenIndex = source.index.prefixToken(byteOffset)
  if tokenIndex < 0 or not source.index.completionContext(tokenIndex):
    return
  if source.index.implicitNameKind(uint32(tokenIndex)) != implicitNone:
    return
  let active = source.index.scopes.innermostScopeAt(uint32(tokenIndex))
  if not source.index.scopes.isLocalScope(active):
    return

  var distances = initTable[uint32, uint32]()
  if not source.index.scopes.addScopeDistances(active, distances):
    return
  var candidates: seq[VisibleCompletion] = @[]
  var candidateByName = initTable[string, int]()
  var scopeNames = newSeq[HashSet[string]](source.index.scopes.scopes.len)
  for scopeIndex in 1 ..< scopeNames.len:
    scopeNames[scopeIndex] = initHashSet[string]()
  if not source.index.appendVisible(
    active,
    uint32(tokenIndex),
    source.index.parsed.tokens.tokenText(source.index.parsed.tokens[tokenIndex]),
    distances,
    candidates,
    candidateByName,
    scopeNames,
  ):
    return
  candidates.sort(compareCompletion)
  result.state = completionAvailable
  result.replaceStart = source.index.parsed.tokens[tokenIndex].startOffset
  result.replaceEnd = byteOffset
  result.items = newSeqOfCap[CompletionItem](candidates.len)
  for candidate in candidates:
    result.items.add candidate.item

proc completeModuleMembers(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    stdlib: StdlibMap,
    context: MemberContext,
): CompletionResult =
  if workspace == nil or not source.valid or source.index == nil or
      source.index.contentHash != contentFingerprint(source.text) or
      source.index.byteLength != source.text.len or
      source.path.toLowerAscii.endsWith(".nimble") or
      source.path.toLowerAscii.endsWith(".cfg"):
    return
  if context.state != memberContextReady or not source.index.bindingsReady or
      not source.index.nativeIndexSafe():
    return
  let qualifier = source.index.parsed.tokens.tokenText(
    source.index.parsed.tokens[context.qualifierToken]
  )
  if not source.importedUseSupported(context.qualifierToken, qualifier):
    return
  if source.index.moduleDeclarationShadows(context.qualifierToken):
    return
  let qualifierDefinition =
    resolveDefinitionAtToken(workspace, source, context.qualifierToken)
  if qualifierDefinition.kind != definitionUnknown:
    return
  let matched = source.importForQualifier(qualifier)
  if matched.state == importMatchMissing:
    var candidates: seq[VisibleCompletion] = @[]
    var candidateByName = initTable[string, int]()
    for candidate in stdlib.implicitFileMembers(qualifier, context.prefix):
      discard appendCompletionCandidate(
        candidate.name,
        completionMethod,
        identifierKey(context.prefix),
        candidates,
        candidateByName,
      )
    if candidates.len == 0:
      return
    candidates.sort(compareCompletion)
    result.state = completionAvailable
    result.replaceStart = context.replaceStart
    result.replaceEnd = context.replaceEnd
    result.items = newSeqOfCap[CompletionItem](candidates.len)
    for candidate in candidates:
      result.items.add candidate.item
    return
  if matched.state != importMatchUnique or matched.item.synthetic or
      source.index.parsed.conditionalImportDisposition(matched.item) notin
      {importUnconditional, importConditionalActive} or matched.item.excluded.len > 0:
    return
  let catalog = workspace.moduleCatalog()
  if catalog == nil or not catalog.complete:
    return

  var candidates: seq[VisibleCompletion] = @[]
  var candidateByName = initTable[string, int]()
  let owner = workspace.moduleForPath(source.path)
  let project = catalog.resolveModuleName(owner, matched.item.module)
  case project.kind
  of moduleResolved:
    if not workspace.graphComplete:
      return
    let view = workspace.indexViewForFile(project.id)
    if not view.valid or view.index == nil or view.id.value != source.id.value or
        not view.index.nativeIndexSafe():
      return
    let input = projectSurfaceInput(project.module, view.index)
    if not appendProjectMembers(
      input, identifierKey(context.prefix), candidates, candidateByName
    ):
      return
  of moduleMissing:
    if not appendStdlibMembers(
      stdlib, matched.item.module, context.prefix, candidates, candidateByName
    ):
      return
  of moduleAmbiguous, moduleUnknown:
    return

  candidates.sort(compareCompletion)
  result.state = completionAvailable
  result.replaceStart = context.replaceStart
  result.replaceEnd = context.replaceEnd
  result.items = newSeqOfCap[CompletionItem](candidates.len)
  for candidate in candidates:
    result.items.add candidate.item

proc completeAt*(
    workspace: Workspace, source: WorkspaceSnapshot, byteOffset: int, stdlib: StdlibMap
): CompletionResult =
  let context = source.index.memberContext(byteOffset)
  case context.state
  of memberContextReady:
    let binding = source.index.resolveBinding(uint32(context.qualifierToken))
    case binding.state
    of bindingResolved:
      result = completeLocalMembers(
        workspace, source, stdlib, context, binding.declarationToken
      )
    of bindingAmbiguous:
      result = CompletionResult()
    of bindingUnknown:
      if context.qualifierKind == qualifierIndexedSequence:
        result = CompletionResult()
      else:
        let enumReceiver =
          resolveEnumTypeReceiver(workspace, source, uint32(context.qualifierToken))
        if enumReceiver.resolved:
          result = completeEnumMembers(source, context, enumReceiver)
        else:
          result = completeModuleMembers(workspace, source, stdlib, context)
  of memberContextInvalid:
    result = CompletionResult()
  of memberContextAbsent:
    result = completePrimitiveTypes(source, byteOffset)
    if result.state == completionAvailable:
      return
    result = completeConditionNames(source, byteOffset, stdlib)
    if result.state == completionAvailable:
      return
    result = completeLocals(source, byteOffset)
    if result.state == completionAvailable:
      mergeImportedCompletions(workspace, source, stdlib, result)
    else:
      result = completeModuleImportedNames(workspace, source, byteOffset, stdlib)
