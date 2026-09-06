import std/[algorithm, sets, strutils]

import ./definition
import ./references
import ../index/bindings
import ../index/occurrences
import ../index/source_index
import ../index/symbols
import ../index/surfaces
import ../session/ids
import ../session/workspace
import ../stdlib/map
import ../syntax/imports
import ../syntax/lexer

type
  RenameState* = enum
    renameUnavailable
    renameAvailable

  RenameInfo* = object
    state*: RenameState
    matches*: seq[ReferenceMatch]

proc validRenameName(name: string): bool =
  let tokens = lex(name)
  if tokens.len != 1:
    return false
  let token = tokens[0]
  token.startOffset == 0 and token.endOffset == name.len and validIdentifier(token) and
    not isNimKeyword(token) and not isStropped(token)

type FromBinding = object
  sourceToken: uint32
  bindingToken: uint32

proc importToken(tokens: TokenStore, item: ImportInfo): int =
  for tokenIndex, token in tokens:
    if token.startOffset < item.startOffset:
      continue
    if token.endOffset > item.endOffset:
      break
    if token.isKeyword(kwImport):
      return tokenIndex
  -1

proc fromBindings(
    source: WorkspaceSnapshot, item: ImportInfo
): tuple[valid: bool, bindings: seq[FromBinding]] =
  result.valid = true
  if item.form != fromModule or item.synthetic or item.conditional:
    result.valid = false
    return
  let importIndex = source.index.parsed.tokens.importToken(item)
  if importIndex < 0:
    result.valid = false
    return
  let tokens = source.index.parsed.tokens
  var cursor = importIndex + 1
  while cursor < tokens.len and tokens[cursor].endOffset <= item.endOffset:
    while cursor < tokens.len and tokens[cursor].endOffset <= item.endOffset and
        (tokens[cursor].kind != tkIdentifier or tokens[cursor].isKeyword(kwAs)):
      if tokens[cursor].isKeyword(kwExcept):
        result.valid = false
        return
      inc cursor
    if cursor >= tokens.len or tokens[cursor].startOffset >= item.endOffset:
      break
    if tokens[cursor].isKeyword(kwExcept):
      result.valid = false
      return
    let sourceToken = cursor
    var bindingToken = cursor
    inc cursor
    if cursor < tokens.len and tokens[cursor].endOffset <= item.endOffset and
        tokens[cursor].isKeyword(kwAs):
      inc cursor
      if cursor >= tokens.len or tokens[cursor].kind != tkIdentifier or
          tokens[cursor].endOffset > item.endOffset:
        result.valid = false
        return
      bindingToken = cursor
      inc cursor
    result.bindings.add FromBinding(
      sourceToken: uint32(sourceToken), bindingToken: uint32(bindingToken)
    )
    while cursor < tokens.len and tokens[cursor].endOffset <= item.endOffset and
        tokens[cursor].text != ",":
      if tokens[cursor].isKeyword(kwExcept):
        result.valid = false
        return
      inc cursor
    if cursor < tokens.len and tokens[cursor].text == ",":
      inc cursor

proc addMatch(matches: var seq[ReferenceMatch], match: ReferenceMatch) =
  for existing in matches:
    if existing.fileId.value == match.fileId.value and
        existing.tokenIndex == match.tokenIndex:
      return
  matches.add match

proc addFromImportMatches(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    target: DefinitionTarget,
    targetName: string,
    matches: var seq[ReferenceMatch],
): bool =
  for dependentId in workspace.dependents(target.fileId):
    let dependent = workspace.snapshotForFile(dependentId)
    if not dependent.valid or dependent.id.value != source.id.value or
        dependent.index == nil or not dependent.index.nativeIndexSafe():
      return false
    for item in dependent.index.parsed.imports:
      if item.form != fromModule or
          workspace.resolveModule(dependent.fileId, item.module).value !=
          target.fileId.value:
        continue
      let bindings = fromBindings(dependent, item)
      if not bindings.valid:
        return false
      for binding in bindings.bindings:
        let token = dependent.index.parsed.tokens[int(binding.sourceToken)]
        if sameIdentifier(token.text, targetName):
          matches.addMatch ReferenceMatch(
            fileId: dependent.fileId,
            contentGeneration: dependent.contentGeneration,
            tokenIndex: binding.sourceToken,
          )
  true

proc moduleNameCollision(
    view: WorkspaceIndexView, target: DefinitionTarget, newKey: string
): bool =
  if not view.valid or view.index == nil:
    return true
  for symbol in view.index.symbols:
    if symbol.nameToken == target.nameToken or
        symbol.nameToken >= uint32(view.index.parsed.tokens.len):
      continue
    if identifierKey(view.index.parsed.tokens[int(symbol.nameToken)].text) == newKey:
      return true
  false

proc importedBindingCollision(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    target: DefinitionTarget,
    targetName: string,
    newKey: string,
): bool =
  for item in source.index.parsed.imports:
    if item.form != fromModule:
      continue
    let parsed = fromBindings(source, item)
    if not parsed.valid:
      return true
    let moduleId = workspace.resolveModule(source.fileId, item.module)
    for binding in parsed.bindings:
      let bindingToken = source.index.parsed.tokens[int(binding.bindingToken)]
      if identifierKey(bindingToken.text) != newKey:
        continue
      let sourceToken = source.index.parsed.tokens[int(binding.sourceToken)]
      if moduleId.value == target.fileId.value and
          sameIdentifier(sourceToken.text, targetName):
        continue
      return true
  false

proc stdlibNameCollision(stdlib: StdlibMap, module, newKey: string): bool =
  if stdlib == nil or not stdlib.surfaceIsComplete:
    return true
  let surface = stdlib.surfaceIndex
  var resolution = surface.lookupInModule(module, newKey)
  if resolution.kind == surfaceUnresolved and not module.startsWith("std/"):
    resolution = surface.lookupInModule("std/" & module, newKey)
  resolution.kind in {surfaceResolved, surfaceAmbiguous, surfaceUnknown}

proc importedModuleCollision(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    target: DefinitionTarget,
    newKey: string,
): bool =
  var stdlib: StdlibMap
  for item in source.index.parsed.imports:
    if item.form != importModule or item.alias.len > 0:
      continue
    if item.synthetic or item.conditional or item.excluded.len > 0:
      return true
    let moduleId = workspace.resolveModule(source.fileId, item.module)
    if moduleId.valid:
      if moduleId.value == target.fileId.value:
        continue
      let view = workspace.indexViewForFile(moduleId)
      if not view.valid or view.index == nil or not view.index.nativeIndexSafe():
        return true
      for symbol in view.index.symbols:
        if not symbol.exported or
            symbol.nameToken >= uint32(view.index.parsed.tokens.len):
          continue
        if identifierKey(view.index.parsed.tokens[int(symbol.nameToken)].text) == newKey:
          return true
    else:
      if stdlib == nil:
        stdlib = stdlibMap()
      let surface = stdlib.surfaceIndex
      if not surface.moduleKnown(item.module) and
          not surface.moduleKnown("std/" & item.module):
        return true
      if stdlib.stdlibNameCollision(item.module, newKey):
        return true
  false

proc qualifiedMember(source: WorkspaceSnapshot, tokenIndex: uint32): bool =
  let index = int(tokenIndex)
  index > 0 and source.index.parsed.tokens[index - 1].text == "." and
    occurrenceMember in source.index.occurrences.rolesForToken(tokenIndex)

proc validateMatches(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    target: DefinitionTarget,
    targetName, newName: string,
    matches: openArray[ReferenceMatch],
): bool =
  if target.kind != targetDeclaration:
    return false
  let oldKey = identifierKey(targetName)
  let newKey = identifierKey(newName)
  if oldKey.len == 0 or newKey.len == 0:
    return false
  let targetView = workspace.indexViewForFile(target.fileId)
  if not targetView.valid or targetView.index == nil or
      targetView.id.value != source.id.value or
      targetView.contentGeneration.value != target.contentGeneration.value or
      target.nameToken >= uint32(targetView.index.parsed.tokens.len) or
      not targetView.index.nativeIndexSafe():
    return false
  let targetToken = targetView.index.parsed.tokens[int(target.nameToken)]
  if targetToken.kind != tkIdentifier or not validIdentifier(targetToken) or
      identifierKey(targetToken.text) != oldKey:
    return false
  let targetSymbolIndex = targetView.index.symbols.symbolToken(target.nameToken)
  let exported =
    targetSymbolIndex >= 0 and targetView.index.symbols[targetSymbolIndex].exported
  if not exported and target.fileId.value != source.fileId.value:
    return false
  if newKey != oldKey and exported and targetView.moduleNameCollision(target, newKey):
    return false
  if newKey != oldKey and not exported and
      source.localTargetHasCompetingDeclaration(target):
    return false
  if newKey != oldKey and
      importedBindingCollision(workspace, source, target, targetName, newKey):
    return false

  for match in matches:
    let current =
      if match.fileId.value == source.fileId.value:
        source
      else:
        workspace.snapshotForFile(match.fileId)
    if not current.valid or current.id.value != source.id.value or
        current.contentGeneration.value != match.contentGeneration.value or
        current.index == nil or not current.index.nativeIndexSafe() or
        match.tokenIndex >= uint32(current.index.parsed.tokens.len):
      return false
    let token = current.index.parsed.tokens[int(match.tokenIndex)]
    if token.kind != tkIdentifier or not validIdentifier(token) or
        identifierKey(token.text) != oldKey:
      return false
    if newKey == oldKey or current.qualifiedMember(match.tokenIndex):
      continue
    if current.index.parsed.tokenInsideImport(token):
      var foundSource = false
      var aliasedSource = false
      for item in current.index.parsed.imports:
        if item.form != fromModule:
          continue
        let parsed = fromBindings(current, item)
        if not parsed.valid:
          return false
        for binding in parsed.bindings:
          if binding.sourceToken == match.tokenIndex:
            foundSource = true
            aliasedSource = binding.bindingToken != binding.sourceToken
      if not foundSource:
        return false
      if aliasedSource:
        continue
    if newKey == "result" and current.index.inRoutineScope(match.tokenIndex):
      return false
    if current.localDeclarationShadows(int(match.tokenIndex), newName):
      return false
    if exported:
      let currentView = workspace.indexViewForFile(current.fileId)
      if currentView.moduleNameCollision(
        DefinitionTarget(kind: targetDeclaration, nameToken: high(uint32)), newKey
      ):
        return false
    if importedBindingCollision(workspace, current, target, targetName, newKey):
      return false
    if importedModuleCollision(workspace, current, target, newKey):
      return false
  true

proc resolveRename*(
    workspace: Workspace, source: WorkspaceSnapshot, byteOffset: int, newName: string
): RenameInfo =
  if workspace == nil or not source.valid or source.index == nil or
      not validRenameName(newName):
    return
  let references = resolveReferences(workspace, source, byteOffset, true)
  if not references.supported or references.target.kind != targetDeclaration or
      references.matches.len == 0:
    return
  var matches = references.matches
  let targetView = workspace.indexViewForFile(references.target.fileId)
  if not targetView.valid or targetView.index == nil or
      references.target.nameToken >= uint32(targetView.index.parsed.tokens.len):
    return
  let targetName = targetView.index.parsed.tokens[int(references.target.nameToken)].text
  let targetSymbolIndex =
    targetView.index.symbols.symbolToken(references.target.nameToken)
  if targetSymbolIndex >= 0 and targetView.index.symbols[targetSymbolIndex].exported and
      not addFromImportMatches(
        workspace, source, references.target, targetName, matches
      ):
    return
  matches.sort(compareReferenceMatches)
  if not validateMatches(
    workspace, source, references.target, targetName, newName, matches
  ):
    return
  result.state = renameAvailable
  result.matches = matches
