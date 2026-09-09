import std/[algorithm, tables]

import ./completion_candidates
import ./completion_context
import ./completion_models
import ../index/scopes
import ../index/source_index
import ../index/type_expression_syntax
import ../index/type_kinds
import ../index/types
import ../session/workspace
import ../session/workspace_models
import ../syntax/tokens

proc completePrimitiveTypes*(
    source: WorkspaceSnapshot, byteOffset: int
): CompletionResult =
  if not source.valid or source.index == nil or byteOffset < 0 or
      byteOffset > source.text.len:
    return
  let tokenIndex = source.index.prefixToken(byteOffset)
  if tokenIndex < 0 or not source.index.completionContext(tokenIndex):
    return
  var inAnnotation = false
  for declaration in source.index.scopes.declarations:
    if declaration.kind in {declarationLet, declarationVar, declarationConst} and
        source.index.parsed.tokens.directTypeAnnotationToken(declaration, tokenIndex):
      inAnnotation = true
      break
  if not inAnnotation:
    return
  var candidates: seq[VisibleCompletion] = @[]
  var candidateByName = initTable[string, int]()
  let prefix =
    source.index.parsed.tokens.tokenText(source.index.parsed.tokens[tokenIndex])
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
  result.replaceStart = source.index.parsed.tokens[tokenIndex].startOffset
  result.replaceEnd = byteOffset
  result.items = newSeqOfCap[CompletionItem](candidates.len)
  for candidate in candidates:
    result.items.add candidate.item
