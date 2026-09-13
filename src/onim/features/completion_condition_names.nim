import std/[algorithm, strutils, tables]

import ./completion_candidates
import ./completion_context
import ./completion_models
import ../index/source_index
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
  let tokens = source.index.parsed.tokens
  var prefix = ""
  var replaceStart = byteOffset
  if tokenIndex >= 0:
    if tokenIndex <= 0 or not tokens[tokenIndex - 1].isKeyword(kwWhen):
      return
    let validContext =
      source.index.completionContext(tokenIndex) or tokens[tokenIndex].isKeyword(kwIs)
    if not validContext:
      return
    prefix = tokens.tokenText(tokens[tokenIndex])
    replaceStart = tokens[tokenIndex].startOffset
  else:
    let previous = source.index.previousToken(byteOffset)
    if previous < 0 or not tokens[previous].isKeyword(kwWhen) or
        not horizontalGap(source.text, tokens[previous].endOffset, byteOffset):
      return
  var candidates: seq[VisibleCompletion] = @[]
  var candidateByName = initTable[string, int]()
  for _, values in stdlib.symbols:
    for candidate in values:
      if candidate.kind == "skConst" and candidate.signature.contains("{.magic") and
          stdlib.implicitModule(candidate.module):
        discard appendStdlibCandidate(
          candidate,
          completionConstant,
          identifierKey(prefix),
          candidates,
          candidateByName,
        )
  if candidates.len == 0:
    return
  candidates.sort(compareCompletion)
  result.state = completionAvailable
  result.insertStart = replaceStart
  result.insertEnd = byteOffset
  result.replaceStart = replaceStart
  result.replaceEnd = byteOffset
  result.items = newSeqOfCap[CompletionItem](candidates.len)
  for candidate in candidates:
    result.items.add candidate.item
