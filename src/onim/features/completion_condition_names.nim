import std/[algorithm, strutils, tables]

import ./completion_candidates
import ./completion_context
import ./completion_models
import ../index/source_index
import ../session/workspace
import ../session/workspace_models
import ../stdlib/map
import ../syntax/tokens

proc completeConditionNames*(
    source: WorkspaceSnapshot, byteOffset: int, stdlib: StdlibMap
): CompletionResult =
  if not source.valid or source.index == nil or stdlib == nil or byteOffset < 0 or
      byteOffset > source.text.len:
    return
  let tokenIndex = source.index.prefixToken(byteOffset)
  if tokenIndex <= 0 or not source.index.completionContext(tokenIndex) or
      not source.index.parsed.tokens[tokenIndex - 1].isKeyword(kwWhen):
    return
  var candidates: seq[VisibleCompletion] = @[]
  var candidateByName = initTable[string, int]()
  let prefix =
    source.index.parsed.tokens.tokenText(source.index.parsed.tokens[tokenIndex])
  for _, values in stdlib.symbols:
    for candidate in values:
      if candidate.kind == "skConst" and candidate.signature.contains("{.magic") and
          stdlib.implicitModule(candidate.module):
        discard appendCompletionCandidate(
          candidate.name,
          completionConstant,
          identifierKey(prefix),
          candidates,
          candidateByName,
        )
  if candidates.len == 0:
    return
  candidates.sort(compareCompletion)
  result.state = completionAvailable
  result.replaceStart = source.index.parsed.tokens[tokenIndex].startOffset
  result.replaceEnd = byteOffset
  result.items = newSeqOfCap[CompletionItem](candidates.len)
  for candidate in candidates:
    result.items.add candidate.item
