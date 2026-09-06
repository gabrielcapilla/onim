import std/strutils

import ../index/bindings
import ../index/source_index
import ../index/symbols
import ../index/scopes
import ../index/types
import ../session/ids
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

  LocalTypeResolution* = object
    info*: LocalTypeInfo
    snapshotId*: SnapshotId
    fileId*: FileId
    contentGeneration*: ContentGeneration

proc unknownResolution(kind = definitionUnknown): DefinitionResolution =
  DefinitionResolution(kind: kind)

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
    if identifierKey(index.parsed.tokens[tokenIndex].text) == wanted:
      result.add symbolIndex

proc routineKind(kind: SourceSymbolKind): bool =
  kind in {
    symbolProc, symbolFunc, symbolIterator, symbolMethod, symbolMacro, symbolTemplate,
    symbolConverter,
  }

proc routineHasBody[T](tokens: T, symbol: SourceSymbol): bool =
  let nameIndex = int(symbol.nameToken)
  if nameIndex < 0 or nameIndex + 1 >= tokens.len:
    return false
  var nesting = 0
  for cursor in nameIndex + 1 ..< tokens.len:
    if cursor > nameIndex + 1 and tokens[cursor].line > tokens[nameIndex].line and
        tokens[cursor].column == 0:
      break
    case tokens[cursor].text
    of "(", "[", "{":
      inc nesting
    of ")", "]", "}":
      if nesting > 0:
        dec nesting
    of "=":
      if nesting == 0:
        return true
    else:
      discard
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
      if identifierKey(source.index.parsed.tokens[int(declaration.nameToken)].text) ==
          wanted:
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

proc qualifiedMember[T](tokens: T, tokenIndex: int): tuple[qualifier, member: int] =
  result = (-1, -1)
  if tokenIndex < 2 or tokens[tokenIndex - 1].text != ".":
    return
  let qualifier = tokenIndex - 2
  if tokens[qualifier].kind != tkIdentifier or
      tokens[qualifier].line != tokens[tokenIndex].line or (
    qualifier > 0 and tokens[qualifier - 1].text == "." and
    tokens[qualifier - 1].line == tokens[qualifier].line
  ) or (tokenIndex + 1 < tokens.len and tokens[tokenIndex + 1].text == "."):
    return
  result = (qualifier, tokenIndex)

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
    result.info = LocalTypeInfo()
    return

  let resolution = resolveDefinitionAtToken(workspace, source, int(local.typeToken))
  if resolution.kind != definitionResolved or resolution.target.kind != targetDeclaration or
      not resolution.target.fileId.valid:
    result.info = LocalTypeInfo()
    return

  var targetSource: WorkspaceSnapshot
  if resolution.target.fileId.value == source.fileId.value:
    if resolution.target.snapshotId.value != source.id.value or
        resolution.target.contentGeneration.value != source.contentGeneration.value:
      result.info = LocalTypeInfo()
      return
    targetSource = source
  else:
    targetSource = workspace.snapshotForFile(resolution.target.fileId)
    if not targetSource.valid or targetSource.id.value != source.id.value or
        targetSource.contentGeneration.value != resolution.target.contentGeneration.value or
        targetSource.index == nil or not targetSource.index.nativeIndexSafe():
      result.info = LocalTypeInfo()
      return

  let symbolIndex = targetSource.index.symbols.symbolToken(resolution.target.nameToken)
  if symbolIndex < 0 or symbolIndex >= targetSource.index.symbols.len:
    result.info = LocalTypeInfo()
    return
  case targetSource.index.symbols[symbolIndex].kind
  of symbolType:
    result.info.kind = localTypeNamed
  of symbolProc, symbolFunc:
    let returnInfo = targetSource.index.types.routineReturnAt(
      targetSource.index.parsed.tokens, targetSource.index.symbols, symbolIndex
    )
    if returnInfo.kind != localTypeNamed:
      result.info = LocalTypeInfo()
      return
    result.info = returnInfo
    result.snapshotId = targetSource.id
    result.fileId = targetSource.fileId
    result.contentGeneration = targetSource.contentGeneration
  else:
    result.info = LocalTypeInfo()

proc resolveObjectReceiver*(
    workspace: Workspace, source: WorkspaceSnapshot, receiverDeclarationToken: uint32
): ObjectReceiverResolution =
  if workspace == nil or not validSource(source) or source.index == nil or
      not source.index.bindingsReady or not source.index.nativeIndexSafe():
    return
  let localType = workspace.resolveLocalType(source, receiverDeclarationToken)
  if localType.info.kind != localTypeNamed:
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
  result.resolved = true
  result.typeTarget = typeResolution.target
  result.provider = provider
  result.objectOrdinal = uint32(objectOrdinal)
  result.exportedOnly = exportedOnly

proc resolveObjectField(
    source: WorkspaceSnapshot, receiver: ObjectReceiverResolution, memberToken: int
): DefinitionResolution =
  if not receiver.resolved or receiver.provider == nil or memberToken < 0 or
      memberToken >= source.index.parsed.tokens.len:
    return unknownResolution(definitionUnsupported)
  let provider = receiver.provider
  let objectOrdinal = int(receiver.objectOrdinal)
  if objectOrdinal < 0 or objectOrdinal >= provider.types.objects.len:
    return unknownResolution(definitionUnsupported)
  let objectType = provider.types.objects[objectOrdinal]
  if objectType.firstField > objectType.pastField or
      objectType.pastField > uint32(provider.types.fields.len):
    return unknownResolution(definitionUnsupported)
  var matched = -1
  let wanted = source.index.parsed.tokens[memberToken].text
  for fieldIndex in objectType.firstField ..< objectType.pastField:
    let field = provider.types.fields[int(fieldIndex)]
    if receiver.exportedOnly and field.visibility != objectFieldExported:
      continue
    if field.nameToken >= uint32(provider.parsed.tokens.len):
      return unknownResolution(definitionUnsupported)
    if not sameIdentifier(provider.parsed.tokens[int(field.nameToken)].text, wanted):
      continue
    if matched >= 0:
      return unknownResolution(definitionAmbiguous)
    matched = int(fieldIndex)
  if matched < 0:
    return unknownResolution(definitionUnsupported)
  let field = provider.types.fields[matched]
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

  let matches = symbolMatches(source.index, token.text)
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
      let receiver =
        resolveObjectReceiver(workspace, source, qualifierBinding.declarationToken)
      if not receiver.resolved:
        return unknownResolution(definitionUnsupported)
      return resolveObjectField(source, receiver, qualified.member)
    of bindingAmbiguous:
      return unknownResolution(definitionAmbiguous)
    of bindingUnknown:
      if not source.importedUseSupported(
        qualified.qualifier, source.index.parsed.tokens[qualified.qualifier].text
      ):
        return
    return resolveQualified(
      workspace,
      source,
      source.index.parsed.tokens[qualified.qualifier].text,
      token.text,
    )
  if tokenIndex + 1 < source.index.parsed.tokens.len and
      source.index.parsed.tokens[tokenIndex + 1].text == ".":
    return
  if not source.importedUseSupported(tokenIndex, token.text):
    return

  let fromState = fromBindingState(source, token.text)
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
  result = resolveFrom(workspace, source, token.text)

proc resolveDefinition*(
    workspace: Workspace, source: WorkspaceSnapshot, byteOffset: int
): DefinitionResolution =
  if workspace == nil or not validSource(source):
    return unknownResolution()
  let tokenIndex = tokenAtOffset(source.index.parsed.tokens, byteOffset)
  if tokenIndex < 0:
    return unknownResolution()
  resolveDefinitionAtToken(workspace, source, tokenIndex)
