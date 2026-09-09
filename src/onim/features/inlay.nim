import ../features/definition
import ../features/definition_models
import ../index/scopes
import ../index/source_index
import ../index/symbols
import ../index/type_ids
import ../index/type_local_models
import ../index/type_local_resolution
import ../index/type_states
import ../index/types
import ../session/workspace
import ../session/workspace_models
import ../syntax/tokens

type InlayHintInfo* = object
  declarationToken*: uint32
  typeResolution*: LocalTypeResolution

proc appendInferredHint(
    source: WorkspaceSnapshot,
    firstOffset, pastOffset: int,
    declarationToken: uint32,
    resolution: LocalTypeResolution,
    result: var seq[InlayHintInfo],
) =
  if resolution.info.state != typeStateResolved or not resolution.info.typeId.valid or
      declarationToken >= uint32(source.index.parsed.tokens.len):
    return
  let token = source.index.parsed.tokens[int(declarationToken)]
  if token.startOffset < firstOffset or token.startOffset >= pastOffset:
    return
  result.add InlayHintInfo(
    declarationToken: declarationToken, typeResolution: resolution
  )

proc inferredInlayHints*(
    workspace: Workspace, source: WorkspaceSnapshot, firstOffset, pastOffset: int
): seq[InlayHintInfo] =
  if workspace == nil or not source.valid or source.index == nil or
      not source.index.nativeIndexSafe() or firstOffset < 0 or pastOffset <= firstOffset:
    return
  for declaration in source.index.scopes.declarations:
    if declaration.kind notin {declarationLet, declarationVar, declarationConst} or
        declaration.nameToken >= uint32(source.index.parsed.tokens.len):
      continue
    let token = source.index.parsed.tokens[int(declaration.nameToken)]
    if token.startOffset < firstOffset or token.startOffset >= pastOffset:
      continue
    let raw = source.index.types.localTypeAt(
      source.index.parsed.tokens, source.index.scopes, declaration.nameToken
    )
    if raw.form notin {localTypeFormCall, localTypeFormLiteral}:
      continue
    let resolved = workspace.resolveLocalType(source, declaration.nameToken)
    source.appendInferredHint(
      firstOffset, pastOffset, declaration.nameToken, resolved, result
    )
  for symbol in source.index.symbols:
    if symbol.kind notin {symbolLet, symbolVar, symbolConst}:
      continue
    let raw = source.index.types.moduleValueTypeAt(source.index.parsed.tokens, symbol)
    if raw.form != localTypeFormLiteral:
      continue
    let resolved = LocalTypeResolution(
      info: raw,
      snapshotId: source.id,
      fileId: source.fileId,
      contentGeneration: source.contentGeneration,
    )
    source.appendInferredHint(
      firstOffset, pastOffset, symbol.nameToken, resolved, result
    )
