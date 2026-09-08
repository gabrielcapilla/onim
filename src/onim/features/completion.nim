import std/[algorithm, sets, strutils, tables]

import ./definition
import ../index/bindings
import ../index/occurrences
import ../index/scopes
import ../index/source_index
import ../index/symbols
import ../index/surfaces
import ../index/types
import ../stdlib/map
import ../session/ids
import ../session/module_catalog
import ../session/workspace
import ../syntax/imports
import ../syntax/lexer

type
  CompletionState* = enum
    completionUnsupported
    completionAvailable

  CompletionKind* = enum
    completionVariable
    completionConstant
    completionFunction
    completionMethod
    completionField
    completionType

  CompletionItem* = object
    label*: string
    kind*: CompletionKind

  CompletionResult* = object
    state*: CompletionState
    replaceStart*: int
    replaceEnd*: int
    items*: seq[CompletionItem]

  VisibleCompletion = object
    item: CompletionItem
    key: string
    distance: uint32
    declarationToken: uint32

  MemberContextState = enum
    memberContextAbsent
    memberContextInvalid
    memberContextReady

  MemberQualifierKind = enum
    qualifierIdentifier
    qualifierIndexedSequence

  MemberContext = object
    state: MemberContextState
    qualifierKind: MemberQualifierKind
    qualifierToken: int
    indexToken: int
    prefix: string
    replaceStart: int
    replaceEnd: int

  ImportMatchState = enum
    importMatchMissing
    importMatchUnique
    importMatchAmbiguous

  ImportMatch = object
    state: ImportMatchState
    item: ImportInfo

  FieldVisibility = enum
    fieldsAll
    fieldsExported

  ImportedSelectionKind = enum
    importedSelectionSkip
    importedSelectionAll
    importedSelectionNamed

  ImportedName = object
    localName: string
    providerName: string

  ImportedSelection = object
    kind: ImportedSelectionKind
    names: seq[ImportedName]

proc scopeOrdinal(scope: ScopeId): int {.inline.} =
  int(uint32(scope)) - 1

proc prefixToken(index: SourceIndex, byteOffset: int): int =
  if index == nil or byteOffset <= 0 or byteOffset > index.byteLength:
    return -1
  let candidate = index.parsed.tokens.tokenAtOffset(byteOffset - 1)
  if candidate < 0 or candidate >= index.parsed.tokens.len:
    return -1
  if index.parsed.tokens[candidate].endOffset != byteOffset:
    return -1
  candidate

proc memberContext(index: SourceIndex, byteOffset: int): MemberContext =
  if index == nil or byteOffset <= 0 or byteOffset > index.byteLength:
    return
  let candidate = index.parsed.tokens.tokenContaining(byteOffset - 1, byteOffset)
  if candidate < 0 or index.parsed.tokens[candidate].endOffset != byteOffset:
    return

  var dotToken = -1
  var memberToken = -1
  let token = index.parsed.tokens[candidate]
  if token.kind == tkIdentifier:
    memberToken = candidate
    dotToken = candidate - 1
    result.replaceStart = token.startOffset
    result.replaceEnd = byteOffset
  elif token.kind == tkPunctuation and index.parsed.tokens.tokenTextEquals(token, "."):
    dotToken = candidate
    result.replaceStart = byteOffset
    result.replaceEnd = byteOffset
  else:
    return

  if dotToken < 0 or dotToken >= index.parsed.tokens.len or
      index.parsed.tokens[dotToken].kind != tkPunctuation or
      not index.parsed.tokens.tokenTextEquals(index.parsed.tokens[dotToken], "."):
    if memberToken >= 0:
      return
    result.state = memberContextInvalid
    return

  let dot = index.parsed.tokens[dotToken]
  let qualifier = qualifierBeforeDot(index.parsed.tokens, dotToken)
  if qualifier.qualifier < 0 or
      index.parsed.tokens[dotToken - 1].endOffset != dot.startOffset:
    result.state = memberContextInvalid
    return
  if memberToken >= 0:
    let member = index.parsed.tokens[memberToken]
    if member.line != dot.line or member.startOffset != dot.endOffset or
        not member.validIdentifier or member.isStropped or member.isNimKeyword:
      result.state = memberContextInvalid
      return

  result.state = memberContextReady
  result.qualifierKind =
    if qualifier.indexToken >= 0: qualifierIndexedSequence else: qualifierIdentifier
  result.qualifierToken = qualifier.qualifier
  result.indexToken = qualifier.indexToken
  result.prefix =
    if memberToken >= 0:
      index.parsed.tokens.tokenText(index.parsed.tokens[memberToken])
    else:
      ""

proc declarationToken(index: SourceIndex, tokenIndex: uint32): bool {.inline.} =
  for symbol in index.symbols:
    if symbol.nameToken == tokenIndex:
      return true
  for declaration in index.scopes.declarations:
    if declaration.nameToken == tokenIndex:
      return true
  false

proc completionContext(index: SourceIndex, tokenIndex: int): bool =
  if tokenIndex < 0 or tokenIndex >= index.parsed.tokens.len:
    return false
  let token = index.parsed.tokens[tokenIndex]
  if token.kind != tkIdentifier or not token.validIdentifier or token.isStropped or
      token.isNimKeyword or index.parsed.tokens.tokenTextLen(token) == 0 or
      index.parsed.tokenInsideImport(token) or index.declarationToken(
    uint32(tokenIndex)
  ):
    return false
  if (
    tokenIndex > 0 and
    index.parsed.tokens.tokenTextEquals(index.parsed.tokens[tokenIndex - 1], ".")
  ) or (
    tokenIndex + 1 < index.parsed.tokens.len and
    index.parsed.tokens.tokenTextEquals(index.parsed.tokens[tokenIndex + 1], ".")
  ):
    return false
  index.occurrences.rolesForToken(uint32(tokenIndex)) == {occurrenceReference}

proc importedQualifier(item: ImportInfo): string {.inline.} =
  if item.alias.len > 0:
    item.alias
  else:
    moduleLeaf(item.module)

proc moduleDeclarationShadows(index: SourceIndex, tokenIndex: int): bool =
  if index == nil or tokenIndex < 0 or tokenIndex >= index.parsed.tokens.len:
    return true
  let wanted = identifierKey(index.parsed.tokens, index.parsed.tokens[tokenIndex])
  if wanted.len == 0:
    return true
  for symbol in index.symbols:
    if symbol.nameToken == uint32(tokenIndex) or
        symbol.nameToken >= uint32(index.parsed.tokens.len):
      continue
    if identifierKey(index.parsed.tokens, index.parsed.tokens[int(symbol.nameToken)]) ==
        wanted:
      return true
  false

proc importForQualifier(source: WorkspaceSnapshot, qualifier: string): ImportMatch =
  if source.index == nil or qualifier.len == 0:
    return
  for item in source.index.parsed.imports:
    if item.form != importModule or not sameIdentifier(
      item.importedQualifier, qualifier
    ):
      continue
    case result.state
    of importMatchMissing:
      result.state = importMatchUnique
      result.item = item
    of importMatchUnique, importMatchAmbiguous:
      result.state = importMatchAmbiguous
      return

proc appendCompletionCandidate(
    name: string,
    kind: CompletionKind,
    prefixKey: string,
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
): bool =
  let key = identifierKey(name)
  if key.len == 0 or (prefixKey.len > 0 and not key.startsWith(prefixKey)):
    return true
  let visible = VisibleCompletion(
    item: CompletionItem(label: name, kind: kind),
    key: key,
    declarationToken: high(uint32),
  )
  if not candidateByName.hasKey(key):
    candidateByName[key] = candidates.len
    candidates.add visible
  elif ord(visible.item.kind) < ord(candidates[candidateByName[key]].item.kind):
    candidates[candidateByName[key]] = visible
  true

proc importedSelection(source: WorkspaceSnapshot, item: ImportInfo): ImportedSelection =
  if source.index == nil or item.synthetic or
      source.index.parsed.conditionalImportDisposition(item) notin
      {importUnconditional, importConditionalActive}:
    return
  case item.form
  of importModule:
    if item.alias.len == 0:
      result.kind = importedSelectionAll
  of fromModule:
    result.kind = importedSelectionNamed
    for imported in item.importedSymbols:
      let binding =
        fromImportBinding(source.index.parsed.tokens, source.text, item, imported.name)
      if binding.kind in {fromImportPlain, fromImportAlias}:
        result.names.add ImportedName(
          localName: imported.name, providerName: binding.providerName
        )
    if result.names.len == 0:
      result.kind = importedSelectionSkip

proc excludedImportName(item: ImportInfo, name: string): bool {.inline.} =
  for excluded in item.excluded:
    if sameIdentifier(excluded, name):
      return true

proc selectedImportedName(
    selection: ImportedSelection, providerName: string
): string {.inline.} =
  case selection.kind
  of importedSelectionAll:
    result = providerName
  of importedSelectionNamed:
    for imported in selection.names:
      if sameIdentifier(imported.providerName, providerName):
        return imported.localName
  of importedSelectionSkip:
    discard

proc appendImportedCandidate(
    name, providerKey: string,
    kind: CompletionKind,
    prefixKey: string,
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
    importedProviders: var Table[string, string],
    ambiguousNames: var HashSet[string],
): bool =
  let key = identifierKey(name)
  if key.len == 0 or (prefixKey.len > 0 and not key.startsWith(prefixKey)):
    return true
  if key in ambiguousNames:
    return true
  if candidateByName.hasKey(key):
    if not importedProviders.hasKey(key):
      return true
    if importedProviders[key] == providerKey:
      return true
    candidates[candidateByName[key]].key = ""
    candidateByName.del(key)
    importedProviders.del(key)
    ambiguousNames.incl(key)
    return true
  discard appendCompletionCandidate(name, kind, prefixKey, candidates, candidateByName)
  if candidateByName.hasKey(key):
    importedProviders[key] = providerKey
  true

proc compareCompletion(left, right: VisibleCompletion): int =
  result = cmp(left.key, right.key)
  if result != 0:
    return
  result = cmp(left.item.label, right.item.label)
  if result != 0:
    return
  result = cmp(left.declarationToken, right.declarationToken)

proc memberCompletionKind(kind: SourceSymbolKind): CompletionKind {.inline.} =
  case kind
  of symbolConst:
    completionConstant
  of symbolMethod:
    completionMethod
  of symbolType:
    completionType
  of symbolProc, symbolFunc, symbolIterator, symbolMacro, symbolTemplate,
      symbolConverter:
    completionFunction
  of symbolVar, symbolLet:
    completionVariable

proc appendProjectMembers(
    input: SurfaceInput,
    prefixKey: string,
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
): bool =
  if input.module.len == 0 or input.uncertainty != {}:
    return false
  for exported in input.exports:
    if not exported.kindKnown or identifierKey(exported.name).len == 0:
      return false
    discard appendCompletionCandidate(
      exported.name,
      memberCompletionKind(exported.kind),
      prefixKey,
      candidates,
      candidateByName,
    )
  true

proc stdlibModuleName(stdlib: StdlibMap, reference: string): string =
  if stdlib == nil or not stdlib.surfaceIsComplete:
    return
  let surface = stdlib.surfaceIndex()
  if surface == nil or not surface.valid or not surface.universeIsComplete:
    return
  let canonical = canonicalSurfaceModule(reference)
  if canonical.startsWith("std/") and surface.moduleKnown(canonical):
    return canonical

proc appendStdlibMembers(
    stdlib: StdlibMap,
    module, prefix: string,
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
): bool =
  let moduleName = stdlib.stdlibModuleName(module)
  if moduleName.len == 0:
    return false
  let surface = stdlib.surfaceIndex()
  var bindings: seq[BindingCandidate] = @[]
  if not surface.appendBindingsInModule(moduleName, prefix, bindings):
    return false
  for binding in bindings:
    let exports = surface.exportsFor(binding)
    if exports.len == 0:
      return false
    discard appendCompletionCandidate(
      binding.name,
      memberCompletionKind(exports[0].kind),
      identifierKey(prefix),
      candidates,
      candidateByName,
    )
  true

proc appendProjectImport(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    item: ImportInfo,
    owner: string,
    catalog: ModuleCatalog,
    prefixKey: string,
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
    importedProviders: var Table[string, string],
    ambiguousNames: var HashSet[string],
): bool =
  if catalog == nil or not catalog.complete or not workspace.graphComplete:
    return true
  let project = catalog.resolveModuleName(owner, item.module)
  if project.kind != moduleResolved:
    return true
  let view = workspace.indexViewForFile(project.id)
  if not view.valid or view.index == nil or view.id.value != source.id.value or
      not view.index.nativeIndexSafe():
    return true
  let input = projectSurfaceInput(project.module, view.index)
  if input.module.len == 0 or input.uncertainty != {}:
    return true
  let selection = source.importedSelection(item)
  if selection.kind == importedSelectionSkip:
    return true
  for exported in input.exports:
    if not exported.kindKnown:
      continue
    if selection.kind == importedSelectionAll and item.excludedImportName(exported.name):
      continue
    let localName = selection.selectedImportedName(exported.name)
    if localName.len == 0:
      continue
    discard appendImportedCandidate(
      localName,
      canonicalModule(project.module) & "|" & identifierKey(exported.name),
      memberCompletionKind(exported.kind),
      prefixKey,
      candidates,
      candidateByName,
      importedProviders,
      ambiguousNames,
    )
  true

proc appendStdlibImport(
    stdlib: StdlibMap,
    source: WorkspaceSnapshot,
    item: ImportInfo,
    prefixKey: string,
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
    importedProviders: var Table[string, string],
    ambiguousNames: var HashSet[string],
): bool =
  let module = stdlib.stdlibModuleName(item.module)
  if module.len == 0:
    return true
  let selection = source.importedSelection(item)
  if selection.kind == importedSelectionSkip:
    return true
  let surface = stdlib.surfaceIndex()
  var bindings: seq[BindingCandidate] = @[]
  if not surface.appendBindingsInModule(module, "", bindings):
    return true
  for binding in bindings:
    let exports = surface.exportsFor(binding)
    if exports.len == 0:
      continue
    if selection.kind == importedSelectionAll and item.excludedImportName(binding.name):
      continue
    let localName = selection.selectedImportedName(binding.name)
    if localName.len == 0:
      continue
    discard appendImportedCandidate(
      localName,
      module & "|" & identifierKey(binding.name),
      memberCompletionKind(exports[0].kind),
      prefixKey,
      candidates,
      candidateByName,
      importedProviders,
      ambiguousNames,
    )
  true

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

proc unsupportedStructure(index: SourceIndex): bool =
  for symbol in index.symbols:
    if symbol.kind in {symbolMacro, symbolTemplate}:
      return true
  for token in index.parsed.tokens:
    if token.kind != tkIdentifier or token.isStropped or
        index.parsed.tokenInsideImport(token):
      continue
    if token.hasKeywordRole(roleConditional) or token.hasKeywordRole(roleInclude) or
        token.hasKeywordRole(roleGenerated):
      return true
    if token.hasKeywordRole(roleBlock) and not token.isKeyword(kwBlock):
      return true
  false

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

proc addScopeDistances(
    index: ScopeIndex, active: ScopeId, distances: var Table[uint32, uint32]
): bool =
  var current = active
  while current != InvalidScopeId:
    let ordinal = current.scopeOrdinal
    if ordinal < 0 or ordinal >= index.scopes.len:
      return false
    let scope = index.scopes[ordinal]
    if scope.kind == scopeModule:
      return distances.len > 0
    if scope.kind notin {scopeRoutine, scopeBlock}:
      return false
    distances[uint32(current)] = uint32(distances.len)
    current = index.parentScope(current)
  false

proc appendVisible(
    index: SourceIndex,
    active: ScopeId,
    cursorToken: uint32,
    prefix: string,
    distances: Table[uint32, uint32],
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
    scopeNames: var seq[HashSet[string]],
): bool =
  for declaration in index.scopes.declarations:
    let nameIndex = int(declaration.nameToken)
    if nameIndex < 0 or nameIndex >= index.parsed.tokens.len:
      return false
    let token = index.parsed.tokens[nameIndex]
    if token.kind != tkIdentifier or not token.validIdentifier or token.isStropped or
        token.isNimKeyword:
      return false
    let distance = distances.getOrDefault(uint32(declaration.scope), high(uint32))
    if distance == high(uint32) or
        not index.scopes.isScopeAncestor(declaration.scope, active):
      continue
    let key = identifierKey(index.parsed.tokens, token)
    if key.len == 0:
      return false
    let scopeOrdinal = declaration.scope.scopeOrdinal
    if scopeOrdinal <= 0 or scopeOrdinal >= scopeNames.len:
      return false
    if key in scopeNames[scopeOrdinal]:
      return false
    scopeNames[scopeOrdinal].incl key
    if declaration.nameToken >= cursorToken:
      continue
    if not key.startsWith(identifierKey(prefix)):
      continue

    let item = CompletionItem(
      label: index.parsed.tokens.tokenText(token),
      kind:
        if declaration.kind == declarationConst:
          completionConstant
        else:
          completionVariable,
    )
    let visible = VisibleCompletion(
      item: item, key: key, distance: distance, declarationToken: declaration.nameToken
    )
    if not candidateByName.hasKey(key):
      candidateByName[key] = candidates.len
      candidates.add visible
    elif distance < candidates[candidateByName[key]].distance:
      candidates[candidateByName[key]] = visible
  true

proc appendObjectFields(
    index: SourceIndex,
    fields: openArray[ObjectField],
    objectType: ObjectTypeRecord,
    prefixKey: string,
    visibility: FieldVisibility,
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
): bool =
  if index == nil or objectType.firstField > objectType.pastField or
      objectType.pastField > uint32(fields.len):
    return false
  for fieldIndex in objectType.firstField ..< objectType.pastField:
    let tokenIndex = int(fields[int(fieldIndex)].nameToken)
    if tokenIndex < 0 or tokenIndex >= index.parsed.tokens.len:
      return false
    if visibility == fieldsExported and
        fields[int(fieldIndex)].visibility != objectFieldExported:
      continue
    let token = index.parsed.tokens[tokenIndex]
    if not appendCompletionCandidate(
      index.parsed.tokens.tokenText(token),
      completionField,
      prefixKey,
      candidates,
      candidateByName,
    ):
      return false
  true

proc completeEnumMembers(
    source: WorkspaceSnapshot,
    context: MemberContext,
    receiver: ObjectReceiverResolution,
): CompletionResult =
  if not receiver.resolved or receiver.provider == nil:
    return
  var candidates: seq[VisibleCompletion] = @[]
  var candidateByName = initTable[string, int]()
  let objectOrdinal = int(receiver.objectOrdinal)
  if objectOrdinal < 0 or objectOrdinal >= receiver.provider.types.objects.len or
      not appendObjectFields(
        receiver.provider,
        receiver.provider.types.fields,
        receiver.provider.types.objects[objectOrdinal],
        identifierKey(context.prefix),
        if receiver.exportedOnly: fieldsExported else: fieldsAll,
        candidates,
        candidateByName,
      ) or candidates.len == 0:
    return
  candidates.sort(compareCompletion)
  result.state = completionAvailable
  result.replaceStart = context.replaceStart
  result.replaceEnd = context.replaceEnd
  result.items = newSeqOfCap[CompletionItem](candidates.len)
  for candidate in candidates:
    result.items.add candidate.item

proc appendUfcsCandidate(
    name, prefixKey: string,
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
): bool =
  let key = identifierKey(name)
  if key.len == 0 or (prefixKey.len > 0 and not key.startsWith(prefixKey)):
    return true
  if candidateByName.hasKey(key) and
      candidates[candidateByName[key]].item.kind == completionField:
    return true
  appendCompletionCandidate(
    name, completionMethod, prefixKey, candidates, candidateByName
  )

proc appendUfcsMembers(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    receiver: LocalTypeResolution,
    prefixKey: string,
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
): bool =
  let matches = collectUfcsTargets(workspace, source, receiver, prefixKey = prefixKey)
  if matches.state != typeStateResolved:
    return false
  for target in matches.targets:
    var view = workspace.indexViewForFile(target.fileId)
    if target.fileId.value == source.fileId.value and not view.valid:
      view = WorkspaceIndexView(
        valid: source.valid,
        id: source.id,
        fileId: source.fileId,
        contentGeneration: source.contentGeneration,
        index: source.index,
      )
    if not view.valid or view.index == nil or
        target.nameToken >= uint32(view.index.parsed.tokens.len):
      return false
    let symbolIndex = view.index.symbols.symbolToken(target.nameToken)
    if symbolIndex < 0 or symbolIndex >= view.index.symbols.len:
      return false
    let name = view.index.parsed.tokens.tokenText(
      view.index.parsed.tokens[int(target.nameToken)]
    )
    if not appendUfcsCandidate(name, prefixKey, candidates, candidateByName):
      return false
  true

proc appendImplicitFileMembers(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    stdlib: StdlibMap,
    typeInfo: LocalTypeInfo,
    prefix: string,
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
): bool =
  if typeInfo.kind != typeNamed or
      typeInfo.typeToken >= uint32(source.index.parsed.tokens.len):
    return false
  let typeToken = source.index.parsed.tokens[int(typeInfo.typeToken)]
  if not source.index.parsed.tokens.tokenTextEquals(typeToken, "File"):
    return false
  if resolveDefinitionAtToken(workspace, source, int(typeInfo.typeToken)).kind !=
      definitionUnknown:
    return false
  for candidate in stdlib.implicitFileMembers(prefix):
    result = true
    discard appendCompletionCandidate(
      candidate.name,
      completionMethod,
      identifierKey(prefix),
      candidates,
      candidateByName,
    )

proc stdlibDirectCall(
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

proc appendStdlibDirectCallMembers(
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

proc stdlibNominalTypeModule(
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
  if typeName.len == 0 or source.index.moduleDeclarationShadows(typeToken) or
      not source.importedUseSupported(typeToken, typeName) or
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

proc appendStdlibNominalMembers(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    stdlib: StdlibMap,
    localType: LocalTypeResolution,
    prefix: string,
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
): bool =
  let module = stdlibNominalTypeModule(workspace, source, stdlib, localType)
  if module.len == 0:
    return
  let typeName = source.index.parsed.tokens.tokenText(
    source.index.parsed.tokens[int(localType.info.typeToken)]
  )
  let before = candidates.len
  for candidate in stdlib.directNominalMembers(module, typeName, prefix):
    discard appendCompletionCandidate(
      candidate.name,
      completionMethod,
      identifierKey(prefix),
      candidates,
      candidateByName,
    )
  candidates.len > before

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
    result = completeLocals(source, byteOffset)
    if result.state == completionAvailable:
      mergeImportedCompletions(workspace, source, stdlib, result)
    else:
      result = completeModuleImportedNames(workspace, source, byteOffset, stdlib)
