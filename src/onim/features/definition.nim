import std/strutils
import std/sets

import ../index/bindings
import ../index/source_index
import ../index/symbols
import ../index/scopes
import ../index/types
import ../index/surfaces
import ../session/ids
import ../session/module_catalog
import ../session/workspace
import ../syntax/imports
import ../syntax/lexer

type
  DefinitionResolutionKind* = enum
    definitionUnknown
    definitionUnresolved
    definitionAmbiguous
    definitionUnsupported
    definitionResolved

  DefinitionTargetKind* = enum
    targetDeclaration
    targetObjectField

  ObjectFieldSource* = enum
    objectFieldsNominal
    objectFieldsLocalTuple

  DefinitionTarget* = object
    kind*: DefinitionTargetKind
    snapshotId*: SnapshotId
    fileId*: FileId
    contentGeneration*: ContentGeneration
    nameToken*: uint32

  DefinitionResolution* = object
    kind*: DefinitionResolutionKind
    target*: DefinitionTarget

  ObjectReceiverResolution* = object
    resolved*: bool
    typeTarget*: DefinitionTarget
    provider*: SourceIndex
    objectOrdinal*: uint32
    exportedOnly*: bool
    fieldSource*: ObjectFieldSource

  LocalTypeResolution* = object
    info*: LocalTypeInfo
    snapshotId*: SnapshotId
    fileId*: FileId
    contentGeneration*: ContentGeneration

proc unknownResolution(kind = definitionUnknown): DefinitionResolution =
  DefinitionResolution(kind: kind)

proc sameDefinitionTarget*(left, right: DefinitionTarget): bool {.inline.} =
  left.kind == right.kind and left.snapshotId.value == right.snapshotId.value and
    left.fileId.value == right.fileId.value and
    left.contentGeneration.value == right.contentGeneration.value and
    left.nameToken == right.nameToken

proc typeStateForDefinition(kind: DefinitionResolutionKind): TypeState {.inline.} =
  case kind
  of definitionUnresolved: typeStateUnresolved
  of definitionAmbiguous: typeStateAmbiguous
  of definitionResolved: typeStateResolved
  of definitionUnknown, definitionUnsupported: typeStateUnknown

proc validSource(source: WorkspaceSnapshot): bool =
  source.valid and source.index != nil and
    source.index.contentHash == contentFingerprint(source.text) and
    source.index.byteLength == source.text.len

proc localTarget(
    source: WorkspaceSnapshot, declarationToken: uint32
): DefinitionResolution =
  if declarationToken >= uint32(source.index.parsed.tokens.len):
    return unknownResolution()
  result.kind = definitionResolved
  result.target = DefinitionTarget(
    kind: targetDeclaration,
    snapshotId: source.id,
    fileId: source.fileId,
    contentGeneration: source.contentGeneration,
    nameToken: declarationToken,
  )

proc localTargetHasCompetingDeclaration*(
    source: WorkspaceSnapshot, target: DefinitionTarget
): bool =
  if target.kind != targetDeclaration:
    return true
  if source.index == nil or target.nameToken >= uint32(source.index.parsed.tokens.len):
    return true
  let binding = source.index.resolveBinding(target.nameToken)
  binding.state != bindingResolved or binding.declarationToken != target.nameToken

proc resolveLocalDefinitionAtToken*(
    source: WorkspaceSnapshot, tokenIndex: int
): DefinitionResolution =
  if not validSource(source) or not source.index.bindingsReady or tokenIndex < 0 or
      tokenIndex >= source.index.parsed.tokens.len:
    return unknownResolution()
  let token = source.index.parsed.tokens[tokenIndex]
  if token.kind != tkIdentifier or source.index.parsed.tokenInsideImport(token):
    return unknownResolution()
  let binding = source.index.resolveBinding(uint32(tokenIndex))
  case binding.state
  of bindingAmbiguous:
    unknownResolution(definitionAmbiguous)
  of bindingResolved:
    localTarget(source, binding.declarationToken)
  of bindingUnknown:
    unknownResolution()

proc symbolMatches(index: SourceIndex, name: string, exportedOnly = false): seq[int] =
  if index == nil:
    return
  let wanted = identifierKey(name)
  if wanted.len == 0:
    return
  for symbolIndex, symbol in index.symbols:
    let tokenIndex = int(symbol.nameToken)
    if tokenIndex < 0 or tokenIndex >= index.parsed.tokens.len:
      continue
    if exportedOnly and not symbol.exported:
      continue
    if identifierKey(index.parsed.tokens, index.parsed.tokens[tokenIndex]) == wanted:
      result.add symbolIndex

proc routineKind*(kind: SourceSymbolKind): bool =
  kind in {
    symbolProc, symbolFunc, symbolIterator, symbolMethod, symbolMacro, symbolTemplate,
    symbolConverter,
  }

proc routineHasBody(tokens: TokenStore, symbol: SourceSymbol): bool =
  let nameIndex = int(symbol.nameToken)
  if nameIndex < 0 or nameIndex + 1 >= tokens.len:
    return false
  var nesting = 0
  for cursor in nameIndex + 1 ..< tokens.len:
    if cursor > nameIndex + 1 and tokens[cursor].line > tokens[nameIndex].line and
        tokens[cursor].column == 0:
      break
    if tokens.tokenTextEquals(tokens[cursor], "(") or
        tokens.tokenTextEquals(tokens[cursor], "[") or
        tokens.tokenTextEquals(tokens[cursor], "{"):
      inc nesting
    elif tokens.tokenTextEquals(tokens[cursor], ")") or
        tokens.tokenTextEquals(tokens[cursor], "]") or
        tokens.tokenTextEquals(tokens[cursor], "}"):
      if nesting > 0:
        dec nesting
    elif tokens.tokenTextEquals(tokens[cursor], "="):
      if nesting == 0:
        return true
  false

proc completeSymbol(index: SourceIndex, symbolIndex: int): bool =
  if index == nil or symbolIndex < 0 or symbolIndex >= index.symbols.len:
    return false
  let symbol = index.symbols[symbolIndex]
  if int(symbol.nameToken) >= index.parsed.tokens.len:
    return false
  not symbol.kind.routineKind or routineHasBody(index.parsed.tokens, symbol)

proc targetFor(
    source: WorkspaceSnapshot, view: WorkspaceIndexView, symbolIndex: int
): DefinitionResolution =
  if not view.valid or view.index == nil or view.id.value != source.id.value or
      symbolIndex < 0 or symbolIndex >= view.index.symbols.len:
    return unknownResolution(definitionUnresolved)
  let symbol = view.index.symbols[symbolIndex]
  if int(symbol.nameToken) >= view.index.parsed.tokens.len:
    return unknownResolution()
  if not completeSymbol(view.index, symbolIndex):
    return unknownResolution()
  result.kind = definitionResolved
  result.target = DefinitionTarget(
    kind: targetDeclaration,
    snapshotId: source.id,
    fileId: view.fileId,
    contentGeneration: view.contentGeneration,
    nameToken: symbol.nameToken,
  )

proc resolveSymbolTarget*(
    source: WorkspaceSnapshot, view: WorkspaceIndexView, symbolIndex: int
): DefinitionResolution =
  targetFor(source, view, symbolIndex)

proc addTarget(targets: var seq[DefinitionTarget], target: DefinitionTarget) =
  for existing in targets:
    if existing.kind == target.kind and existing.fileId.value == target.fileId.value and
        existing.nameToken == target.nameToken:
      return
  targets.add target

proc finishTargets(
    targets: seq[DefinitionTarget], unresolved: bool
): DefinitionResolution =
  if unresolved:
    return unknownResolution(definitionUnresolved)
  if targets.len == 0:
    return unknownResolution()
  if targets.len > 1:
    return unknownResolution(definitionAmbiguous)
  result.kind = definitionResolved
  result.target = targets[0]

proc hasExcept(imports: SourceImports, item: ImportInfo): bool =
  for token in imports.tokens:
    if token.startOffset < item.startOffset or token.endOffset > item.endOffset:
      continue
    if token.isKeyword(kwExcept):
      return true
  false

proc plainImported(source: string, symbol: ImportSymbol): bool =
  if symbol.startOffset < 0 or symbol.endOffset < symbol.startOffset or
      symbol.endOffset > source.len:
    return false
  source[symbol.startOffset ..< symbol.endOffset].strip(chars = {'`'}) == symbol.name

proc excludedImport(item: ImportInfo, name: string): bool =
  for excluded in item.excluded:
    if sameIdentifier(excluded, name):
      return true
  false

proc fromBindingState(
    source: WorkspaceSnapshot, name: string
): tuple[found, uncertain: bool] =
  for item in source.index.parsed.imports:
    if item.form != fromModule:
      continue
    for symbol in item.importedSymbols:
      if not sameIdentifier(symbol.name, name):
        continue
      result.found = true
      if item.conditional or item.synthetic or hasExcept(source.index.parsed, item) or
          not plainImported(source.text, symbol):
        result.uncertain = true

proc localDeclarationShadows*(
    source: WorkspaceSnapshot, tokenIndex: int, name: string
): bool =
  if source.index == nil or not source.index.bindingsReady or tokenIndex < 0 or
      tokenIndex >= source.index.parsed.tokens.len:
    return true
  let wanted = identifierKey(name)
  if wanted.len == 0:
    return true
  var scope = source.index.scopes.innermostScopeAt(uint32(tokenIndex))
  while source.index.scopes.isLocalScope(scope):
    for declaration in source.index.scopes.declarations:
      if declaration.scope != scope or declaration.nameToken == uint32(tokenIndex) or
          declaration.nameToken >= uint32(source.index.parsed.tokens.len):
        continue
      if identifierKey(
        source.index.parsed.tokens,
        source.index.parsed.tokens[int(declaration.nameToken)],
      ) == wanted:
        return true
    scope = source.index.scopes.parentScope(scope)
  false

proc importedUseSupported*(
    source: WorkspaceSnapshot, tokenIndex: int, name: string
): bool =
  if source.index == nil or not source.index.bindingsReady or tokenIndex < 0 or
      tokenIndex >= source.index.parsed.tokens.len:
    return false
  let binding = source.index.resolveBinding(uint32(tokenIndex))
  if binding.state != bindingUnknown:
    return false
  if source.index.implicitNameKind(uint32(tokenIndex)) != implicitNone:
    return false
  not source.localDeclarationShadows(tokenIndex, name)

proc integerIndexToken(tokens: TokenStore, tokenIndex: int): bool {.inline.} =
  if tokenIndex < 0 or tokenIndex >= tokens.len or tokens[tokenIndex].kind != tkNumber:
    return false
  var digits = 0
  for index in 0 ..< tokens.tokenTextLen(tokens[tokenIndex]):
    let character = tokens.tokenTextChar(tokens[tokenIndex], index)
    if character == '_':
      continue
    if character < '0' or character > '9':
      return false
    inc digits
  digits > 0

proc qualifierBeforeDot*(
    tokens: TokenStore, dotToken: int
): tuple[qualifier, indexToken: int] =
  result = (-1, -1)
  if dotToken <= 0 or dotToken >= tokens.len or
      not tokens.tokenTextEquals(tokens[dotToken], "."):
    return
  let direct = dotToken - 1
  if tokens[direct].kind == tkIdentifier and tokens[direct].validIdentifier and
      not tokens[direct].isStropped and not tokens[direct].isNimKeyword and
      tokens[direct].line == tokens[dotToken].line and (
    direct == 0 or not tokens.tokenTextEquals(tokens[direct - 1], ".") or
    tokens[direct - 1].line != tokens[direct].line
  ):
    result.qualifier = direct
    return
  let closing = dotToken - 1
  let indexToken = dotToken - 2
  let opening = dotToken - 3
  let qualifier = dotToken - 4
  if qualifier < 0 or not tokens.tokenTextEquals(tokens[opening], "[") or
      not integerIndexToken(tokens, indexToken) or
      not tokens.tokenTextEquals(tokens[closing], "]") or
      tokens[qualifier].kind != tkIdentifier or not tokens[qualifier].validIdentifier or
      tokens[qualifier].isStropped or tokens[qualifier].isNimKeyword or
      tokens[qualifier].line != tokens[dotToken].line or
      tokens[indexToken].line != tokens[dotToken].line or
      tokens[opening].line != tokens[dotToken].line or
      tokens[closing].line != tokens[dotToken].line or (
    qualifier > 0 and tokens.tokenTextEquals(tokens[qualifier - 1], ".") and
    tokens[qualifier - 1].line == tokens[qualifier].line
  ):
    return
  result = (qualifier, indexToken)

proc qualifiedMember(
    tokens: TokenStore, tokenIndex: int
): tuple[qualifier, indexToken, member: int] =
  result = (-1, -1, -1)
  if tokenIndex < 1 or not tokens.tokenTextEquals(tokens[tokenIndex - 1], "."):
    return
  let qualifier = qualifierBeforeDot(tokens, tokenIndex - 1)
  if qualifier.qualifier < 0 or (
    tokenIndex + 1 < tokens.len and tokens.tokenTextEquals(tokens[tokenIndex + 1], ".")
  ):
    return
  result = (qualifier.qualifier, qualifier.indexToken, tokenIndex)

proc qualifierMatches(item: ImportInfo, qualifier: string): bool =
  if item.alias.len > 0:
    sameIdentifier(item.alias, qualifier)
  else:
    sameIdentifier(moduleLeaf(item.module), qualifier)

proc resolveQualified(
    workspace: Workspace, source: WorkspaceSnapshot, qualifier, member: string
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
    let matches = symbolMatches(view.index, member, exportedOnly = true)
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

proc resolveFrom(
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
      if item.conditional or hasExcept(source.index.parsed, item) or
          not plainImported(source.text, imported):
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
      let matches = symbolMatches(view.index, imported.name, exportedOnly = true)
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

proc resolveDefinitionAtToken*(
  workspace: Workspace, source: WorkspaceSnapshot, tokenIndex: int
): DefinitionResolution

proc resolveLocalType*(
    workspace: Workspace, source: WorkspaceSnapshot, declarationToken: uint32
): LocalTypeResolution =
  if workspace == nil or not validSource(source) or source.index == nil:
    return
  let local = source.index.types.localTypeAt(
    source.index.parsed.tokens, source.index.scopes, declarationToken
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

proc enumReceiverInView(
    source: WorkspaceSnapshot,
    view: WorkspaceIndexView,
    name: string,
    exportedOnly: bool,
): ObjectReceiverResolution =
  if not view.valid or view.index == nil or view.id.value != source.id.value:
    return
  let matches = symbolMatches(view.index, name, exportedOnly)
  if matches.len != 1:
    return
  let symbolIndex = matches[0]
  if view.index.symbols[symbolIndex].kind != symbolType:
    return
  let declarationToken = view.index.symbols[symbolIndex].nameToken
  if not simpleEnumDeclaration(view.index.parsed.tokens, declarationToken):
    return
  let objectOrdinal = view.index.types.objectOrdinal(declarationToken)
  if objectOrdinal < 0:
    return
  let target = targetFor(source, view, symbolIndex)
  if target.kind != definitionResolved:
    return
  result.resolved = true
  result.typeTarget = target.target
  result.provider = view.index
  result.objectOrdinal = uint32(objectOrdinal)
  result.exportedOnly = exportedOnly

proc resolveEnumTypeReceiver*(
    workspace: Workspace, source: WorkspaceSnapshot, typeToken: uint32
): ObjectReceiverResolution =
  if workspace == nil or not validSource(source) or source.index == nil or
      typeToken >= uint32(source.index.parsed.tokens.len):
    return
  let name =
    source.index.parsed.tokens.tokenText(source.index.parsed.tokens[int(typeToken)])
  let localView = WorkspaceIndexView(
    valid: source.valid,
    id: source.id,
    fileId: source.fileId,
    contentGeneration: source.contentGeneration,
    index: source.index,
  )
  let local = enumReceiverInView(source, localView, name, exportedOnly = false)
  if local.resolved:
    return local
  if not workspace.graphComplete:
    return
  var found = false
  for item in source.index.parsed.imports:
    var usable = false
    case item.form
    of importModule:
      usable =
        not item.synthetic and item.alias.len == 0 and not item.conditional and
        item.excluded.len == 0
    of fromModule:
      if item.synthetic or item.alias.len > 0 or item.conditional or
          hasExcept(source.index.parsed, item):
        continue
      for symbol in item.importedSymbols:
        if sameIdentifier(symbol.name, name) and plainImported(source.text, symbol):
          usable = true
          break
    if not usable:
      continue
    let moduleId = workspace.resolveModule(source.fileId, item.module)
    if not moduleId.valid:
      continue
    let view = workspace.indexViewForFile(moduleId)
    let candidate = enumReceiverInView(source, view, name, exportedOnly = true)
    if not candidate.resolved:
      continue
    if found:
      return
    result = candidate
    found = true

proc resolveObjectField(
    source: WorkspaceSnapshot, receiver: ObjectReceiverResolution, memberToken: int
): DefinitionResolution =
  if not receiver.resolved or receiver.provider == nil or memberToken < 0 or
      memberToken >= source.index.parsed.tokens.len:
    return unknownResolution(definitionUnsupported)
  let provider = receiver.provider
  let objectOrdinal = int(receiver.objectOrdinal)
  var objectType: ObjectTypeRecord
  var fields: seq[ObjectField]
  case receiver.fieldSource
  of objectFieldsNominal:
    if objectOrdinal < 0 or objectOrdinal >= provider.types.objects.len:
      return unknownResolution(definitionUnsupported)
    objectType = provider.types.objects[objectOrdinal]
    fields = provider.types.fields
  of objectFieldsLocalTuple:
    if objectOrdinal < 0 or objectOrdinal >= provider.types.localTupleObjects.len:
      return unknownResolution(definitionUnsupported)
    objectType = provider.types.localTupleObjects[objectOrdinal]
    fields = provider.types.localTupleFields
  if objectType.firstField > objectType.pastField or
      objectType.pastField > uint32(fields.len):
    return unknownResolution(definitionUnsupported)
  var matched = -1
  let wanted =
    source.index.parsed.tokens.tokenText(source.index.parsed.tokens[memberToken])
  for fieldIndex in objectType.firstField ..< objectType.pastField:
    let field = fields[int(fieldIndex)]
    if receiver.exportedOnly and field.visibility != objectFieldExported:
      continue
    if field.nameToken >= uint32(provider.parsed.tokens.len):
      return unknownResolution(definitionUnsupported)
    if not sameIdentifier(
      provider.parsed.tokens.tokenText(provider.parsed.tokens[int(field.nameToken)]),
      wanted,
    ):
      continue
    if matched >= 0:
      return unknownResolution(definitionAmbiguous)
    matched = int(fieldIndex)
  if matched < 0:
    return unknownResolution(definitionUnsupported)
  let field = fields[matched]
  result.kind = definitionResolved
  result.target = DefinitionTarget(
    kind: targetObjectField,
    snapshotId: source.id,
    fileId: receiver.typeTarget.fileId,
    contentGeneration: receiver.typeTarget.contentGeneration,
    nameToken: field.nameToken,
  )

proc resolveObjectFieldDeclaration(
    source: WorkspaceSnapshot, tokenIndex: int
): DefinitionResolution =
  if not source.index.nativeIndexSafe():
    return unknownResolution(definitionUnsupported)
  let fieldOrdinal = source.index.types.objectFieldOrdinal(uint32(tokenIndex))
  if fieldOrdinal < 0:
    return unknownResolution()
  for objectType in source.index.types.objects:
    if uint32(fieldOrdinal) < objectType.firstField or
        uint32(fieldOrdinal) >= objectType.pastField:
      continue
    let field = source.index.types.fields[fieldOrdinal]
    result.kind = definitionResolved
    result.target = DefinitionTarget(
      kind: targetObjectField,
      snapshotId: source.id,
      fileId: source.fileId,
      contentGeneration: source.contentGeneration,
      nameToken: field.nameToken,
    )
    return
  unknownResolution(definitionUnsupported)

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

proc exactGenericInstanceMatch(
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

type
  UfcsFormalArityKind = enum
    ufcsArityUnknown
    ufcsArityFixed
    ufcsArityVariable

  UfcsCallKind = enum
    ufcsNotCall
    ufcsCallKnown
    ufcsCallUncertain

  UfcsTargetRecord = object
    target: DefinitionTarget
    arityKind: UfcsFormalArityKind
    arity: uint32

proc addUfcsTarget(
    targets: var seq[UfcsTargetRecord],
    target: DefinitionTarget,
    arityKind: UfcsFormalArityKind,
    arity: uint32,
) =
  for existing in targets:
    if existing.target.sameDefinitionTarget(target):
      return
  targets.add UfcsTargetRecord(target: target, arityKind: arityKind, arity: arity)

proc ufcsFormalArity(
    tokens: TokenStore, scopes: ScopeIndex, first: LexicalDeclaration
): tuple[kind: UfcsFormalArityKind, count: uint32] =
  result.kind = ufcsArityUnknown
  if first.kind != declarationParameter:
    return
  let scopeOrdinal = int(uint32(first.scope)) - 1
  if scopeOrdinal < 0 or scopeOrdinal >= scopes.scopes.len:
    return
  for declaration in scopes.declarations:
    if declaration.scope != first.scope or declaration.kind != declarationParameter:
      continue
    if declaration.firstToken >= declaration.pastToken or
        declaration.pastToken > uint32(tokens.len):
      return
    inc result.count
    var delimiters: seq[char] = @[]
    for tokenIndex in int(declaration.firstToken) ..< int(declaration.pastToken):
      let token = tokens[tokenIndex]
      if token.kind == tkPunctuation and tokens.tokenTextLen(token) == 1:
        let value = tokens.tokenTextChar(token, 0)
        if isOpeningDelimiter(value):
          delimiters.add value
          continue
        if isClosingDelimiter(value):
          if delimiters.len == 0 or not matchingDelimiter(delimiters[^1], value):
            return
          delimiters.setLen(delimiters.len - 1)
          continue
        if delimiters.len == 0 and value == '=':
          result.kind = ufcsArityVariable
          return
      if delimiters.len == 0 and tokens.tokenTextEquals(token, "varargs"):
        result.kind = ufcsArityVariable
        return
    if delimiters.len > 0:
      return
  result.kind = ufcsArityFixed

proc ufcsCallArity(
    tokens: TokenStore, memberToken: int
): tuple[kind: UfcsCallKind, count: uint32] =
  if memberToken < 0 or memberToken + 1 >= tokens.len or
      not tokens.tokenTextEquals(tokens[memberToken + 1], "("):
    result.kind = ufcsNotCall
    return
  result.kind = ufcsCallUncertain
  var delimiters = @['(']
  var hasArgument = false
  for tokenIndex in memberToken + 2 ..< tokens.len:
    let token = tokens[tokenIndex]
    if token.kind == tkPunctuation and tokens.tokenTextLen(token) == 1:
      let value = tokens.tokenTextChar(token, 0)
      if isOpeningDelimiter(value):
        delimiters.add value
        hasArgument = true
        continue
      if isClosingDelimiter(value):
        if delimiters.len == 0 or not matchingDelimiter(delimiters[^1], value):
          return
        delimiters.setLen(delimiters.len - 1)
        if delimiters.len == 0:
          if hasArgument:
            inc result.count
          elif result.count > 0:
            return
          result.kind = ufcsCallKnown
          return
        continue
      if delimiters.len == 1 and value == ',':
        if not hasArgument:
          return
        inc result.count
        hasArgument = false
        continue
    if delimiters.len == 1:
      hasArgument = true

proc importedUfcsName(
    workspace: Workspace, source: WorkspaceSnapshot, provider: FileId, name: string
): tuple[state: TypeState, visible: bool] =
  result.state = typeStateResolved
  if workspace == nil or not validSource(source) or source.index == nil:
    result.state = typeStateUnknown
    return
  var uncertain = false
  for item in source.index.parsed.imports:
    if item.synthetic:
      continue
    let imported = workspace.resolveModule(source.fileId, item.module)
    if not imported.valid or imported.value != provider.value:
      continue
    case item.form
    of importModule:
      if item.conditional:
        uncertain = true
      elif item.alias.len == 0 and not item.excludedImport(name):
        result.visible = true
    of fromModule:
      if item.conditional or hasExcept(source.index.parsed, item):
        uncertain = true
        continue
      for symbol in item.importedSymbols:
        if not sameIdentifier(symbol.name, name):
          continue
        if plainImported(source.text, symbol):
          result.visible = true
        else:
          uncertain = true
  if not result.visible and uncertain:
    result.state = typeStateUnresolved

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
  if not workspace.graphComplete:
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
  if local.kind != definitionUnknown:
    return local

  let tokenName = source.index.parsed.tokens.tokenText(token)
  let matches = symbolMatches(source.index, tokenName)
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
    )
  if tokenIndex + 1 < source.index.parsed.tokens.len and
      source.index.parsed.tokens.tokenTextEquals(
        source.index.parsed.tokens[tokenIndex + 1], "."
      ):
    return
  if not source.importedUseSupported(tokenIndex, tokenName):
    return

  let fromState = fromBindingState(source, tokenName)
  if matches.len > 1:
    return unknownResolution(definitionAmbiguous)
  if matches.len == 1:
    let declaration =
      source.index.parsed.tokens[int(source.index.symbols[matches[0]].nameToken)]
    if declaration.startOffset >= token.startOffset:
      return
    if fromState.found:
      return unknownResolution()
    if not completeSymbol(source.index, matches[0]):
      return
    result.kind = definitionResolved
    result.target = DefinitionTarget(
      kind: targetDeclaration,
      snapshotId: source.id,
      fileId: source.fileId,
      contentGeneration: source.contentGeneration,
      nameToken: source.index.symbols[matches[0]].nameToken,
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
