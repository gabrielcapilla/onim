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

  MemberContext = object
    state: MemberContextState
    qualifierToken: int
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
  elif token.kind == tkPunctuation and token.text == ".":
    dotToken = candidate
    result.replaceStart = byteOffset
    result.replaceEnd = byteOffset
  else:
    return

  if dotToken < 0 or dotToken >= index.parsed.tokens.len or
      index.parsed.tokens[dotToken].kind != tkPunctuation or
      index.parsed.tokens[dotToken].text != ".":
    if memberToken >= 0:
      return
    result.state = memberContextInvalid
    return

  let dot = index.parsed.tokens[dotToken]
  let qualifierToken = dotToken - 1
  if qualifierToken < 0 or qualifierToken >= index.parsed.tokens.len or
      dot.line != index.parsed.tokens[qualifierToken].line or
      index.parsed.tokens[qualifierToken].kind != tkIdentifier or
      not index.parsed.tokens[qualifierToken].validIdentifier or
      index.parsed.tokens[qualifierToken].isStropped or
      isNimKeyword(index.parsed.tokens[qualifierToken].text) or
      index.parsed.tokens[qualifierToken].endOffset != dot.startOffset or
      (qualifierToken > 0 and index.parsed.tokens[qualifierToken - 1].text == "."):
    result.state = memberContextInvalid
    return
  if memberToken >= 0:
    let member = index.parsed.tokens[memberToken]
    if member.line != dot.line or member.startOffset != dot.endOffset or
        not member.validIdentifier or member.isStropped or isNimKeyword(member.text):
      result.state = memberContextInvalid
      return

  result.state = memberContextReady
  result.qualifierToken = qualifierToken
  result.prefix =
    if memberToken >= 0:
      index.parsed.tokens[memberToken].text
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
      isNimKeyword(token.text) or token.text.len == 0 or
      index.parsed.tokenInsideImport(token) or index.declarationToken(
    uint32(tokenIndex)
  ):
    return false
  if (tokenIndex > 0 and index.parsed.tokens[tokenIndex - 1].text == ".") or (
    tokenIndex + 1 < index.parsed.tokens.len and
    index.parsed.tokens[tokenIndex + 1].text == "."
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
  let wanted = identifierKey(index.parsed.tokens[tokenIndex].text)
  if wanted.len == 0:
    return true
  for symbol in index.symbols:
    if symbol.nameToken == uint32(tokenIndex) or
        symbol.nameToken >= uint32(index.parsed.tokens.len):
      continue
    if identifierKey(index.parsed.tokens[int(symbol.nameToken)].text) == wanted:
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

proc compareCompletion(left, right: VisibleCompletion): int =
  result = cmp(left.key, right.key)
  if result != 0:
    return
  result = cmp(left.item.label, right.item.label)
  if result != 0:
    return
  result = cmp(left.declarationToken, right.declarationToken)

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
        isNimKeyword(token.text):
      return false
    let distance = distances.getOrDefault(uint32(declaration.scope), high(uint32))
    if distance == high(uint32) or
        not index.scopes.isScopeAncestor(declaration.scope, active):
      continue
    let key = identifierKey(token.text)
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
      label: token.text,
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

proc completeLocalMembers(
    source: WorkspaceSnapshot, context: MemberContext, declarationToken: uint32
): CompletionResult =
  if not source.valid or source.index == nil or not source.index.bindingsReady or
      not source.index.parsed.nativeIndexSafe(source.index):
    return
  let declarationOrdinal = source.index.scopes.declarationOrdinalAt(declarationToken)
  if declarationOrdinal < 0 or declarationOrdinal >= source.index.types.localTypeUses.len:
    return
  let typeToken = source.index.types.localTypeUses[declarationOrdinal]
  let objectOrdinal = source.index.types.objectOrdinalForType(
    source.index.parsed.tokens, source.index.symbols, typeToken
  )
  if objectOrdinal < 0 or objectOrdinal >= source.index.types.objects.len:
    return
  let objectType = source.index.types.objects[objectOrdinal]
  var candidates: seq[VisibleCompletion] = @[]
  var candidateByName = initTable[string, int]()
  for fieldIndex in objectType.firstField ..< objectType.pastField:
    let tokenIndex = int(source.index.types.fields[int(fieldIndex)].nameToken)
    if tokenIndex < 0 or tokenIndex >= source.index.parsed.tokens.len:
      return
    let token = source.index.parsed.tokens[tokenIndex]
    if not appendCompletionCandidate(
      token.text,
      completionField,
      identifierKey(context.prefix),
      candidates,
      candidateByName,
    ):
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
    source.index.parsed.tokens[tokenIndex].text,
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
      not source.index.parsed.nativeIndexSafe(source.index):
    return
  let qualifier = source.index.parsed.tokens[context.qualifierToken].text
  if not source.importedUseSupported(context.qualifierToken, qualifier):
    return
  if source.index.moduleDeclarationShadows(context.qualifierToken):
    return
  let qualifierDefinition =
    resolveDefinitionAtToken(workspace, source, context.qualifierToken)
  if qualifierDefinition.kind != definitionUnknown:
    return
  let matched = source.importForQualifier(qualifier)
  if matched.state != importMatchUnique or matched.item.synthetic or
      matched.item.conditional or matched.item.excluded.len > 0:
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
        not view.index.parsed.nativeIndexSafe(view.index):
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
      completeLocalMembers(source, context, binding.declarationToken)
    of bindingAmbiguous:
      CompletionResult()
    of bindingUnknown:
      completeModuleMembers(workspace, source, stdlib, context)
  of memberContextInvalid:
    CompletionResult()
  of memberContextAbsent:
    completeLocals(source, byteOffset)
