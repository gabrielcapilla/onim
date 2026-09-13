import ../index/source_index
import ../session/workspace_models
import ../syntax/tokens

proc validSource*(source: WorkspaceSnapshot): bool =
  source.valid and source.index != nil and
    source.index.contentHash == contentFingerprint(source.text) and
    source.index.byteLength == source.text.len

proc symbolMatches*(index: SourceIndex, name: string, exportedOnly = false): seq[int] =
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
