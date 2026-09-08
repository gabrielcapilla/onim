import std/algorithm

import ../index/source_index
import ../index/symbols
import ../index/types
import ../session/ids
import ../session/workspace
import ../syntax/lexer
import ./definition

proc receiverType(source: WorkspaceSnapshot, symbolOrdinal: int): LocalTypeInfo =
  if not source.valid or source.index == nil or symbolOrdinal < 0:
    return LocalTypeInfo(state: typeStateUnknown)
  for candidate in source.index.types.ufcsProcedures:
    if int(candidate.symbolOrdinal) != symbolOrdinal or
        candidate.parameterOrdinal >= uint32(source.index.scopes.declarations.len):
      continue
    let parameter = source.index.scopes.declarations[int(candidate.parameterOrdinal)]
    return source.index.types.localTypeAt(
      source.index.parsed.tokens, source.index.scopes, parameter.nameToken
    )
  LocalTypeInfo(state: typeStateUnknown)

proc sameReceiver(
    workspace: Workspace,
    leftSource, rightSource: WorkspaceSnapshot,
    left, right: LocalTypeInfo,
): bool =
  if left.state != typeStateResolved or right.state != typeStateResolved or
      left.kind != right.kind:
    return false
  if left.kind.isPrimitiveType:
    true
  else:
    case left.kind
    of typeNamed, typeRef:
      if left.typeToken == InvalidTypeToken or right.typeToken == InvalidTypeToken:
        return false
      let leftTarget =
        resolveDefinitionAtToken(workspace, leftSource, int(left.typeToken))
      let rightTarget =
        resolveDefinitionAtToken(workspace, rightSource, int(right.typeToken))
      leftTarget.kind == definitionResolved and rightTarget.kind == definitionResolved and
        leftTarget.target.sameDefinitionTarget(rightTarget.target)
    else:
      false

proc addTarget(targets: var seq[DefinitionTarget], target: DefinitionTarget) =
  for existing in targets:
    if existing.sameDefinitionTarget(target):
      return
  targets.add target

proc implementationTargets*(
    workspace: Workspace, source: WorkspaceSnapshot, byteOffset: int
): seq[DefinitionTarget] =
  if workspace == nil or not source.valid or source.index == nil or
      not source.index.nativeIndexSafe():
    return
  let resolution = resolveDefinition(workspace, source, byteOffset)
  if resolution.kind != definitionResolved or resolution.target.kind != targetDeclaration:
    return
  let targetView = workspace.indexViewForFile(resolution.target.fileId)
  if not targetView.valid or targetView.index == nil or
      targetView.id.value != source.id.value or
      targetView.contentGeneration.value != resolution.target.contentGeneration.value:
    return
  let targetSymbol = targetView.index.symbols.symbolToken(resolution.target.nameToken)
  if targetSymbol < 0 or targetView.index.symbols[targetSymbol].kind != symbolMethod:
    return
  let targetSource =
    if targetView.fileId.value == source.fileId.value:
      source
    else:
      workspace.snapshotForFile(targetView.fileId)
  if not targetSource.valid or targetSource.index == nil:
    return
  let targetReceiver = receiverType(targetSource, targetSymbol)
  if targetReceiver.state != typeStateResolved:
    return
  let targetName = targetView.index.parsed.tokens.tokenText(
    targetView.index.parsed.tokens[int(resolution.target.nameToken)]
  )
  let targetKey = identifierKey(targetName)
  if targetKey.len == 0:
    return

  for fileId in workspace.fileIds:
    let candidateSource = workspace.snapshotForFile(fileId)
    if not candidateSource.valid or candidateSource.index == nil or
        not candidateSource.index.nativeIndexSafe():
      continue
    let candidateView = workspace.indexViewForFile(fileId)
    if not candidateView.valid or candidateView.index == nil or
        candidateView.id.value != source.id.value or
        candidateView.contentGeneration.value != candidateSource.contentGeneration.value:
      continue
    for symbolIndex, symbol in candidateView.index.symbols:
      if symbol.kind != symbolMethod or
          symbol.nameToken >= uint32(candidateView.index.parsed.tokens.len):
        continue
      let name = candidateView.index.parsed.tokens.tokenText(
        candidateView.index.parsed.tokens[int(symbol.nameToken)]
      )
      if identifierKey(name) != targetKey:
        continue
      let candidateReceiver = receiverType(candidateSource, symbolIndex)
      if not sameReceiver(
        workspace, targetSource, candidateSource, targetReceiver, candidateReceiver
      ):
        continue
      let candidate = resolveSymbolTarget(source, candidateView, symbolIndex)
      if candidate.kind == definitionResolved:
        result.addTarget(candidate.target)
  result.sort(
    proc(left, right: DefinitionTarget): int =
      result = cmp(left.fileId.value, right.fileId.value)
      if result == 0:
        result = cmp(left.nameToken, right.nameToken)
  )
