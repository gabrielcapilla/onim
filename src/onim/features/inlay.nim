import ../features/definition
import ../index/scopes
import ../index/source_index
import ../index/types
import ../session/workspace

type InlayHintInfo* = object
  declarationToken*: uint32
  typeResolution*: LocalTypeResolution

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
    if resolved.info.state != typeStateResolved or not resolved.info.typeId.valid:
      continue
    result.add InlayHintInfo(
      declarationToken: declaration.nameToken, typeResolution: resolved
    )
