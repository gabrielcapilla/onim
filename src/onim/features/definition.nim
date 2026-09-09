import std/strutils
import std/sets

import ../index/bindings
import ../index/source_index
import ../index/symbols
import ../index/scopes
import ../index/types
import ../index/surfaces
import ../index/type_field_queries
import ../index/type_ids
import ../index/type_kinds
import ../index/type_local_models
import ../index/type_local_resolution
import ../index/type_object_queries
import ../index/type_queries
import ../index/type_routine_returns
import ../index/type_states
import ../index/type_declaration_syntax
import ../session/ids
import ../session/module_catalog
import ../session/workspace
import ../session/workspace_models
import ../stdlib/map
import ../syntax/imports
import ../syntax/import_queries
import ../syntax/module_names
import ../syntax/tokens
import ./definition_visibility
import ./definition_models
import ./definition_import_resolution
import ./definition_enum_receiver
import ./definition_object_fields
import ./definition_local
import ./definition_source_queries
import ./definition_ufcs_visibility
import ./definition_receiver_tokens
import ./definition_resolution_results
import ./definition_routine_filter
import ./definition_symbol_target
import ./definition_symbol_completeness
import ./routine_body
import ./ufcs_arity

proc resolveDefinitionAtToken*(
  workspace: Workspace, source: WorkspaceSnapshot, tokenIndex: int
): DefinitionResolution

proc resolveLocalType*(
    workspace: Workspace, source: WorkspaceSnapshot, declarationToken: uint32
): LocalTypeResolution =
  if workspace == nil or not validSource(source) or source.index == nil:
    return
  var local = source.index.types.localTypeAt(
    source.index.parsed.tokens, source.index.scopes, declarationToken
  )
  if local.state == typeStateUnknown:
    let symbolIndex = source.index.symbols.symbolToken(declarationToken)
    if symbolIndex >= 0:
      local = source.index.types.moduleValueTypeAt(
        source.index.parsed.tokens, source.index.symbols[symbolIndex]
      )
  result.info = local
  result.snapshotId = source.id
  result.fileId = source.fileId
  result.contentGeneration = source.contentGeneration
  if local.form != localTypeFormCall:
    return
  if not source.index.nativeIndexSafe() or
      local.typeToken >= uint32(source.index.parsed.tokens.len):
    result.info = LocalTypeInfo(state: typeStateUnknown)
    return

  let resolution = resolveDefinitionAtToken(workspace, source, int(local.typeToken))
  if resolution.kind != definitionResolved:
    result.info = LocalTypeInfo(state: typeStateForDefinition(resolution.kind))
    return
  if resolution.target.kind != targetDeclaration or not resolution.target.fileId.valid:
    result.info = LocalTypeInfo(state: typeStateUnknown)
    return

  var targetSource: WorkspaceSnapshot
  if resolution.target.fileId.value == source.fileId.value:
    if resolution.target.snapshotId.value != source.id.value or
        resolution.target.contentGeneration.value != source.contentGeneration.value:
      result.info = LocalTypeInfo(state: typeStateUnknown)
      return
    targetSource = source
  else:
    targetSource = workspace.snapshotForFile(resolution.target.fileId)
    if not targetSource.valid or targetSource.id.value != source.id.value or
        targetSource.contentGeneration.value != resolution.target.contentGeneration.value or
        targetSource.index == nil:
      result.info = LocalTypeInfo(state: typeStateUnknown)
      return

  let symbolIndex = targetSource.index.symbols.symbolToken(resolution.target.nameToken)
  if symbolIndex < 0 or symbolIndex >= targetSource.index.symbols.len:
    result.info = LocalTypeInfo(state: typeStateUnknown)
    return
  case targetSource.index.symbols[symbolIndex].kind
  of symbolType:
    if not targetSource.index.nativeIndexSafe():
      result.info = LocalTypeInfo(state: typeStateUnknown)
      return
    result.info.kind = typeNamed
    result.info.state = typeStateResolved
  of symbolMacro, symbolTemplate:
    result.info = LocalTypeInfo(state: typeStateGenerated)
  of symbolProc, symbolFunc:
    if not targetSource.index.nativeIndexSafe():
      result.info = LocalTypeInfo(state: typeStateUnknown)
      return
    let returnInfo = targetSource.index.types.routineReturnAt(
      targetSource.index.parsed.tokens, targetSource.index.symbols, symbolIndex
    )
    if returnInfo.state != typeStateResolved or (
      not returnInfo.kind.isPrimitiveType and
      returnInfo.kind notin {typeNamed, typeRef, typeGenericInstance, typeSeq}
    ):
      result.info = LocalTypeInfo(state: typeStateUnknown)
      return
    result.info = returnInfo
    result.snapshotId = targetSource.id
    result.fileId = targetSource.fileId
    result.contentGeneration = targetSource.contentGeneration
  else:
    result.info = LocalTypeInfo(state: typeStateUnknown)

proc resolveReceiverType*(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    declarationToken: uint32,
    indexToken = InvalidTypeToken,
): LocalTypeResolution =
  result = workspace.resolveLocalType(source, declarationToken)
  if indexToken == InvalidTypeToken:
    return
  if result.info.state != typeStateResolved or
      result.info.kind notin {typeSeq, typeArray} or
      result.info.typeToken == InvalidTypeToken:
    result.info = LocalTypeInfo(state: typeStateUnknown)
    return
  let baseType = source.index.types.typeBase(result.info.typeId)
  if source.index.types.typeKind(baseType) != typeNamed:
    result.info = LocalTypeInfo(state: typeStateUnknown)
    return
  result.info.kind = typeNamed
  result.info.typeId = baseType

proc resolveObjectReceiver*(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    receiverDeclarationToken: uint32,
    indexToken = InvalidTypeToken,
): ObjectReceiverResolution =
  if workspace == nil or not validSource(source) or source.index == nil or
      not source.index.bindingsReady or not source.index.nativeIndexSafe():
    return
  let localType =
    workspace.resolveReceiverType(source, receiverDeclarationToken, indexToken)
  if localType.info.state != typeStateResolved or
      localType.info.kind notin {typeNamed, typeRef, typeGenericInstance}:
    return
  var typeSource = source
  if localType.fileId.value != source.fileId.value:
    typeSource = workspace.snapshotForFile(localType.fileId)
    if not typeSource.valid or typeSource.id.value != source.id.value or
        typeSource.contentGeneration.value != localType.contentGeneration.value or
        typeSource.index == nil or not typeSource.index.nativeIndexSafe():
      return
  elif localType.contentGeneration.value != source.contentGeneration.value or
      localType.snapshotId.value != source.id.value:
    return
  if localType.info.form == localTypeFormLiteral:
    let tupleToken =
      if localType.info.typeToken == InvalidTypeToken:
        receiverDeclarationToken
      else:
        localType.info.typeToken
    let localTupleOrdinal = source.index.types.localTupleObjectOrdinal(tupleToken)
    if localTupleOrdinal >= 0:
      result.resolved = true
      result.typeTarget = DefinitionTarget(
        kind: targetDeclaration,
        snapshotId: source.id,
        fileId: source.fileId,
        contentGeneration: source.contentGeneration,
        nameToken: tupleToken,
      )
      result.provider = source.index
      result.objectOrdinal = uint32(localTupleOrdinal)
      result.fieldSource = objectFieldsLocalTuple
      return
    if localType.info.typeToken == InvalidTypeToken:
      return
  let typeToken = localType.info.typeToken
  let typeResolution = resolveDefinitionAtToken(workspace, typeSource, int(typeToken))
  if typeResolution.kind != definitionResolved or
      typeResolution.target.kind != targetDeclaration or
      typeResolution.target.snapshotId.value != source.id.value or
      not typeResolution.target.fileId.valid:
    return

  var provider = source.index
  var exportedOnly = false
  if typeResolution.target.fileId.value == source.fileId.value:
    if typeResolution.target.contentGeneration.value != source.contentGeneration.value:
      return
  else:
    let view = workspace.indexViewForFile(typeResolution.target.fileId)
    if not view.valid or view.index == nil or view.id.value != source.id.value or
        view.contentGeneration.value != typeResolution.target.contentGeneration.value or
        not view.index.nativeIndexSafe():
      return
    provider = view.index
    exportedOnly = true

  let objectOrdinal = provider.types.objectOrdinal(typeResolution.target.nameToken)
  if objectOrdinal < 0 or objectOrdinal >= provider.types.objects.len:
    return
  if localType.info.kind == typeGenericInstance:
    let objectType = provider.types.objects[objectOrdinal]
    if objectType.pastGenericParameter <= objectType.firstGenericParameter:
      return
  result.resolved = true
  result.typeTarget = typeResolution.target
  result.provider = provider
  result.objectOrdinal = uint32(objectOrdinal)
  result.exportedOnly = exportedOnly

proc exactNamedTypeMatch(
    workspace: Workspace,
    leftSource, rightSource: WorkspaceSnapshot,
    leftToken, rightToken: uint32,
): tuple[state: TypeState, matches: bool] =
  if leftToken == InvalidTypeToken or rightToken == InvalidTypeToken:
    return
  let leftResolution = resolveDefinitionAtToken(workspace, leftSource, int(leftToken))
  let rightResolution =
    resolveDefinitionAtToken(workspace, rightSource, int(rightToken))
  if leftResolution.kind != definitionResolved:
    result.state = typeStateForDefinition(leftResolution.kind)
    return
  if rightResolution.kind != definitionResolved:
    result.state = typeStateForDefinition(rightResolution.kind)
    return
  result.state = typeStateResolved
  result.matches = leftResolution.target.sameDefinitionTarget(rightResolution.target)

proc exactGenericInstanceMatch*(
    workspace: Workspace,
    leftSource, rightSource: WorkspaceSnapshot,
    left, right: LocalTypeInfo,
): tuple[state: TypeState, matches: bool] =
  if not leftSource.index.types.supportedGenericInstance(left) or
      not rightSource.index.types.supportedGenericInstance(right):
    return
  let constructor = exactNamedTypeMatch(
    workspace, leftSource, rightSource, left.typeToken, right.typeToken
  )
  if constructor.state != typeStateResolved:
    return constructor
  result.state = typeStateResolved
  if not constructor.matches:
    return
  let leftCount = leftSource.index.types.genericArgumentCount(left.typeId)
  let rightCount = rightSource.index.types.genericArgumentCount(right.typeId)
  if leftCount == 0 or leftCount != rightCount:
    return
  for argumentIndex in 0 ..< leftCount:
    let leftArgument =
      leftSource.index.types.genericArgumentType(left.typeId, argumentIndex)
    let rightArgument =
      rightSource.index.types.genericArgumentType(right.typeId, argumentIndex)
    let leftKind = leftSource.index.types.typeKind(leftArgument)
    let rightKind = rightSource.index.types.typeKind(rightArgument)
    if leftKind == typeUnknown or rightKind == typeUnknown:
      result.state = typeStateUnknown
      return
    if leftKind != rightKind:
      return
    if leftKind.isPrimitiveType:
      continue
    if leftKind != typeNamed:
      result.state = typeStateUnknown
      return
    let argumentMatch = exactNamedTypeMatch(
      workspace,
      leftSource,
      rightSource,
      leftSource.index.types.typeNameToken(leftArgument),
      rightSource.index.types.typeNameToken(rightArgument),
    )
    if argumentMatch.state != typeStateResolved:
      return argumentMatch
    if not argumentMatch.matches:
      return
  result.matches = true

proc exactTypeMatch*(
    workspace: Workspace,
    leftSource, rightSource: WorkspaceSnapshot,
    left, right: LocalTypeInfo,
): tuple[state: TypeState, matches: bool] =
  if workspace == nil or not leftSource.valid or not rightSource.valid or
      leftSource.index == nil or rightSource.index == nil:
    return
  if left.state != typeStateResolved:
    result.state = left.state
    return
  if right.state != typeStateResolved:
    result.state = right.state
    return
  if left.kind != right.kind:
    result.state = typeStateResolved
    return
  if left.kind.isPrimitiveType:
    result.state = typeStateResolved
    result.matches = true
    return
  case left.kind
  of typeSeq:
    let leftBase = leftSource.index.types.typeBase(left.typeId)
    let rightBase = rightSource.index.types.typeBase(right.typeId)
    let leftKind = leftSource.index.types.typeKind(leftBase)
    let rightKind = rightSource.index.types.typeKind(rightBase)
    if leftKind == typeUnknown or rightKind == typeUnknown:
      return
    if leftKind == typeNamed and rightKind == typeNamed:
      return exactNamedTypeMatch(
        workspace, leftSource, rightSource, left.typeToken, right.typeToken
      )
    result.state = typeStateResolved
    result.matches = leftKind == rightKind
  of typeArray:
    let leftOrdinal = int(uint32(left.typeId)) - 1
    let rightOrdinal = int(uint32(right.typeId)) - 1
    if leftOrdinal < 0 or leftOrdinal >= leftSource.index.types.records.len or
        rightOrdinal < 0 or rightOrdinal >= rightSource.index.types.records.len:
      return
    let leftRecord = leftSource.index.types.records[leftOrdinal]
    let rightRecord = rightSource.index.types.records[rightOrdinal]
    result.state = typeStateResolved
    result.matches =
      leftRecord.extent == rightRecord.extent and
      leftSource.index.types.typeKind(leftRecord.baseType) ==
      rightSource.index.types.typeKind(rightRecord.baseType)
  of typeNamed, typeRef:
    return exactNamedTypeMatch(
      workspace, leftSource, rightSource, left.typeToken, right.typeToken
    )
  of typeGenericInstance:
    return exactGenericInstanceMatch(workspace, leftSource, rightSource, left, right)
  else:
    discard

proc collectUfcsFromProvider(
    workspace: Workspace,
    source, provider, receiverSource: WorkspaceSnapshot,
    receiver: LocalTypeInfo,
    exactName, prefixKey: string,
    targets: var seq[UfcsTargetRecord],
): TypeState =
  if not provider.valid or provider.index == nil or not provider.index.nativeIndexSafe():
    return typeStateUnresolved
  var view = workspace.indexViewForFile(provider.fileId)
  if provider.fileId.value == source.fileId.value and not view.valid:
    view = WorkspaceIndexView(
      valid: source.valid,
      id: source.id,
      fileId: source.fileId,
      contentGeneration: source.contentGeneration,
      index: provider.index,
    )
  if not view.valid or view.index == nil or view.id.value != source.id.value or
      view.contentGeneration.value != provider.contentGeneration.value:
    return typeStateUnresolved
  let imported = provider.fileId.value != source.fileId.value
  for candidate in provider.index.types.ufcsProcedures:
    if candidate.symbolOrdinal >= uint32(provider.index.symbols.len) or
        candidate.parameterOrdinal >= uint32(provider.index.scopes.declarations.len):
      return typeStateUnknown
    let symbol = provider.index.symbols[int(candidate.symbolOrdinal)]
    if symbol.nameToken >= uint32(provider.index.parsed.tokens.len) or
        symbol.kind notin {symbolProc, symbolFunc, symbolMethod}:
      return typeStateUnknown
    if imported and not symbol.exported:
      continue
    let name = provider.index.parsed.tokens.tokenText(
      provider.index.parsed.tokens[int(symbol.nameToken)]
    )
    let key = identifierKey(name)
    if key.len == 0 or (exactName.len > 0 and not sameIdentifier(name, exactName)) or
        (exactName.len == 0 and prefixKey.len > 0 and not key.startsWith(prefixKey)):
      continue
    if imported:
      let visibility = importedUfcsName(workspace, source, provider.fileId, name)
      if visibility.state != typeStateResolved:
        return visibility.state
      if not visibility.visible:
        continue
    let parameter = provider.index.scopes.declarations[int(candidate.parameterOrdinal)]
    let candidateType = provider.index.types.localTypeAt(
      provider.index.parsed.tokens, provider.index.scopes, parameter.nameToken
    )
    let match =
      exactTypeMatch(workspace, receiverSource, provider, receiver, candidateType)
    if match.state != typeStateResolved:
      return match.state
    if not match.matches:
      continue
    let target = targetFor(source, view, int(candidate.symbolOrdinal))
    if target.kind != definitionResolved:
      return typeStateForDefinition(target.kind)
    let arity =
      ufcsFormalArity(provider.index.parsed.tokens, provider.index.scopes, parameter)
    targets.addUfcsTarget(target.target, arity.kind, arity.count)
  typeStateResolved

proc collectUfcsTargetRecords(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    receiver: LocalTypeResolution,
    exactName = "",
    prefixKey = "",
): tuple[state: TypeState, targets: seq[UfcsTargetRecord]] =
  result.state = typeStateResolved
  if workspace == nil or not validSource(source) or source.index == nil or
      not source.index.nativeIndexSafe() or receiver.info.state != typeStateResolved or
      not receiver.info.typeId.valid or receiver.info.kind == typeUnknown:
    result.state = typeStateUnknown
    return
  var receiverSource = source
  if receiver.fileId.value == source.fileId.value:
    if receiver.snapshotId.value != source.id.value or
        receiver.contentGeneration.value != source.contentGeneration.value:
      result.state = typeStateUnknown
      return
  else:
    receiverSource = workspace.snapshotForFile(receiver.fileId)
    if not receiverSource.valid or receiverSource.id.value != receiver.snapshotId.value or
        receiverSource.contentGeneration.value != receiver.contentGeneration.value or
        receiverSource.index == nil or not receiverSource.index.nativeIndexSafe():
      result.state = typeStateUnknown
      return
  let localState = collectUfcsFromProvider(
    workspace, source, source, receiverSource, receiver.info, exactName, prefixKey,
    result.targets,
  )
  if localState != typeStateResolved:
    result.state = localState
    return
  var providers: seq[FileId] = @[]
  for item in source.index.parsed.imports:
    if item.form notin {importModule, fromModule} or item.synthetic:
      continue
    let provider = workspace.resolveModule(source.fileId, item.module)
    if not provider.valid or provider.value == source.fileId.value:
      continue
    var known = false
    for existing in providers:
      if existing.value == provider.value:
        known = true
        break
    if not known:
      providers.add provider
  if providers.len == 0:
    return
  let catalog = workspace.moduleCatalog()
  if catalog == nil or not catalog.complete():
    return
  let surfaces = workspace.projectSurface()
  if surfaces == nil or not surfaces.valid:
    return
  for providerId in providers:
    let provider = workspace.snapshotForFile(providerId)
    let module = workspace.moduleForPath(provider.path)
    if module.len == 0 or not surfaces.moduleKnown(module):
      result.state = typeStateUnresolved
      return
    let providerState = collectUfcsFromProvider(
      workspace, source, provider, receiverSource, receiver.info, exactName, prefixKey,
      result.targets,
    )
    if providerState != typeStateResolved:
      result.state = providerState
      return

proc collectUfcsTargets*(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    receiver: LocalTypeResolution,
    exactName = "",
    prefixKey = "",
): tuple[state: TypeState, targets: seq[DefinitionTarget]] =
  let records =
    collectUfcsTargetRecords(workspace, source, receiver, exactName, prefixKey)
  result.state = records.state
  for record in records.targets:
    result.targets.add record.target

proc collectUfcsTargets*(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    receiver: LocalTypeInfo,
    exactName = "",
    prefixKey = "",
): tuple[state: TypeState, targets: seq[DefinitionTarget]] =
  let resolution = LocalTypeResolution(
    info: receiver,
    snapshotId: source.id,
    fileId: source.fileId,
    contentGeneration: source.contentGeneration,
  )
  let records =
    collectUfcsTargetRecords(workspace, source, resolution, exactName, prefixKey)
  result.state = records.state
  for record in records.targets:
    result.targets.add record.target

proc resolveUfcsMember(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    receiverDeclarationToken: uint32,
    memberToken: int,
    indexToken = InvalidTypeToken,
): DefinitionResolution =
  if workspace == nil or not validSource(source) or source.index == nil or
      receiverDeclarationToken >= uint32(source.index.parsed.tokens.len) or
      memberToken < 0 or memberToken >= source.index.parsed.tokens.len:
    return unknownResolution(definitionUnsupported)
  let localType =
    workspace.resolveReceiverType(source, receiverDeclarationToken, indexToken)
  let wanted =
    source.index.parsed.tokens.tokenText(source.index.parsed.tokens[memberToken])
  if wanted.len == 0:
    return unknownResolution(definitionUnsupported)
  let matches = collectUfcsTargetRecords(workspace, source, localType, wanted)
  case matches.state
  of typeStateUnresolved:
    return unknownResolution(definitionUnresolved)
  of typeStateAmbiguous:
    return unknownResolution(definitionAmbiguous)
  of typeStateUnknown, typeStateGenerated:
    return unknownResolution(definitionUnsupported)
  of typeStateResolved:
    discard
  if matches.targets.len == 0:
    return unknownResolution(definitionUnsupported)
  let call = ufcsCallArity(source.index.parsed.tokens, memberToken)
  case call.kind
  of ufcsNotCall, ufcsCallUncertain:
    var targets: seq[DefinitionTarget] = @[]
    for record in matches.targets:
      targets.addTarget(record.target)
    finishTargets(targets, unresolved = false)
  of ufcsCallKnown:
    if call.count == high(uint32):
      return unknownResolution(definitionUnsupported)
    let wantedArity = call.count + 1'u32
    var targets: seq[DefinitionTarget] = @[]
    for record in matches.targets:
      if record.arityKind != ufcsArityFixed:
        return unknownResolution(definitionUnsupported)
      if record.arity == wantedArity:
        targets.addTarget(record.target)
    if targets.len == 0:
      return unknownResolution(definitionUnsupported)
    finishTargets(targets, unresolved = false)

proc resolveDefinitionAtToken*(
    workspace: Workspace, source: WorkspaceSnapshot, tokenIndex: int
): DefinitionResolution =
  result = unknownResolution()
  if workspace == nil or not validSource(source) or tokenIndex < 0 or
      tokenIndex >= source.index.parsed.tokens.len:
    return
  let token = source.index.parsed.tokens[tokenIndex]
  if source.index.parsed.tokenInsideImport(token):
    return
  if source.index.types.objectFieldOrdinal(uint32(tokenIndex)) >= 0:
    return resolveObjectFieldDeclaration(source, tokenIndex)
  let local = resolveLocalDefinitionAtToken(source, tokenIndex)
  if local.kind notin {definitionUnknown, definitionAmbiguous}:
    return local

  let tokenName = source.index.parsed.tokens.tokenText(token)
  let matches = symbolMatches(source.index, tokenName)
  let filteredMatches =
    filterRoutineMatches(source.index, matches, source.index.parsed.tokens, tokenIndex)
  if local.kind == definitionAmbiguous and (
    matches.len <= 1 or filteredMatches.len != 1
  ):
    return local
  let declarationIndex = source.index.symbols.symbolToken(uint32(tokenIndex))
  if declarationIndex >= 0:
    if matches.len != 1:
      return unknownResolution(definitionAmbiguous)
    if not completeSymbol(source.index, declarationIndex):
      return
    result.kind = definitionResolved
    result.target = DefinitionTarget(
      kind: targetDeclaration,
      snapshotId: source.id,
      fileId: source.fileId,
      contentGeneration: source.contentGeneration,
      nameToken: uint32(tokenIndex),
    )
    return

  let qualified = qualifiedMember(source.index.parsed.tokens, tokenIndex)
  if qualified.member >= 0:
    if source.index.parsed.tokens[qualified.qualifier].startOffset < 0:
      return
    let qualifierBinding = source.index.resolveBinding(uint32(qualified.qualifier))
    case qualifierBinding.state
    of bindingResolved:
      let receiver = resolveObjectReceiver(
        workspace,
        source,
        qualifierBinding.declarationToken,
        if qualified.indexToken >= 0:
          uint32(qualified.indexToken)
        else:
          InvalidTypeToken,
      )
      if receiver.resolved:
        let field = resolveObjectField(source, receiver, qualified.member)
        if field.kind != definitionUnsupported:
          return field
      return resolveUfcsMember(
        workspace,
        source,
        qualifierBinding.declarationToken,
        qualified.member,
        if qualified.indexToken >= 0:
          uint32(qualified.indexToken)
        else:
          InvalidTypeToken,
      )
    of bindingAmbiguous:
      return unknownResolution(definitionAmbiguous)
    of bindingUnknown:
      if qualified.indexToken >= 0:
        return unknownResolution(definitionUnsupported)
      let enumReceiver =
        resolveEnumTypeReceiver(workspace, source, uint32(qualified.qualifier))
      if enumReceiver.resolved:
        return resolveObjectField(source, enumReceiver, qualified.member)
      if not source.importedUseSupported(
        qualified.qualifier,
        source.index.parsed.tokens.tokenText(
          source.index.parsed.tokens[qualified.qualifier]
        ),
      ):
        return
    return resolveQualified(
      workspace,
      source,
      source.index.parsed.tokens.tokenText(
        source.index.parsed.tokens[qualified.qualifier]
      ),
      tokenName,
      tokenIndex,
    )
  if tokenIndex + 1 < source.index.parsed.tokens.len and
      source.index.parsed.tokens.tokenTextEquals(
        source.index.parsed.tokens[tokenIndex + 1], "."
      ):
    return
  if not source.importedUseSupported(tokenIndex, tokenName):
    return

  let fromState = fromBindingState(source, tokenName)
  if filteredMatches.len > 1:
    return unknownResolution(definitionAmbiguous)
  if filteredMatches.len == 1:
    let declaration = source.index.parsed.tokens[
      int(source.index.symbols[filteredMatches[0]].nameToken)
    ]
    if declaration.startOffset >= token.startOffset:
      return
    if fromState.found:
      return unknownResolution()
    if not completeSymbol(source.index, filteredMatches[0]):
      return
    result.kind = definitionResolved
    result.target = DefinitionTarget(
      kind: targetDeclaration,
      snapshotId: source.id,
      fileId: source.fileId,
      contentGeneration: source.contentGeneration,
      nameToken: source.index.symbols[filteredMatches[0]].nameToken,
    )
    return
  if fromState.uncertain:
    return
  result = resolveFrom(workspace, source, tokenName)

proc resolveDefinition*(
    workspace: Workspace, source: WorkspaceSnapshot, byteOffset: int
): DefinitionResolution =
  if workspace == nil or not validSource(source):
    return unknownResolution()
  let tokenIndex = tokenAtOffset(source.index.parsed.tokens, byteOffset)
  if tokenIndex < 0:
    return unknownResolution()
  resolveDefinitionAtToken(workspace, source, tokenIndex)
