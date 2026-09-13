import std/[algorithm, tables]

import ./completion_candidates
import ./completion_context
import ./completion_models
import ../index/scopes
import ../index/source_index
import ../index/type_expression_syntax
import ../index/type_kinds
import ../session/workspace_models
import ../syntax/tokens

proc completePrimitiveTypes*(
    source: WorkspaceSnapshot, byteOffset: int
): CompletionResult =
  if not source.valid or source.index == nil or byteOffset < 0 or
      byteOffset > source.text.len:
    return
  let tokenIndex = source.index.prefixToken(byteOffset)
  let tokens = source.index.parsed.tokens
  var prefix = ""
  var replaceStart = byteOffset
  var inAnnotation = false
  if tokenIndex >= 0:
    if not source.index.completionContext(tokenIndex):
      return
    prefix = tokens.tokenText(tokens[tokenIndex])
    replaceStart = tokens[tokenIndex].startOffset
    for declaration in source.index.scopes.declarations:
      if declaration.kind in {declarationLet, declarationVar, declarationConst} and
          tokens.directTypeAnnotationToken(declaration, tokenIndex):
        inAnnotation = true
        break
  else:
    let previous = source.index.previousToken(byteOffset)
    if previous < 0 or not tokens.tokenTextEquals(tokens[previous], ":") or
        not horizontalGap(source.text, tokens[previous].endOffset, byteOffset):
      return
    for declaration in source.index.scopes.declarations:
      if declaration.kind notin {declarationLet, declarationVar, declarationConst} or
          previous < int(declaration.firstToken) or
          previous >= int(declaration.pastToken):
        continue
      let split = tokens.splitDeclaration(declaration)
      if split.colon == previous and (split.equals < 0 or previous < split.equals):
        inAnnotation = true
        break
  if not inAnnotation:
    return
  var candidates: seq[VisibleCompletion] = @[]
  var candidateByName = initTable[string, int]()
  for kind in TypeKind:
    if kind.isPrimitiveType:
      discard appendCompletionCandidate(
        kind.primitiveTypeName,
        completionType,
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
