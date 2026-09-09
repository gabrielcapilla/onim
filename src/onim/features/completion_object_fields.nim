import std/tables

import ../index/source_index
import ../index/type_index_models
import ../index/types
import ../syntax/tokens
import ./completion_candidates
import ./completion_models

type FieldVisibility* = enum
  fieldsAll
  fieldsExported

proc appendObjectFields*(
    index: SourceIndex,
    fields: openArray[ObjectField],
    objectType: ObjectTypeRecord,
    prefixKey: string,
    visibility: FieldVisibility,
    candidates: var seq[VisibleCompletion],
    candidateByName: var Table[string, int],
): bool =
  if index == nil or objectType.firstField > objectType.pastField or
      objectType.pastField > uint32(fields.len):
    return false
  for fieldIndex in objectType.firstField ..< objectType.pastField:
    let tokenIndex = int(fields[int(fieldIndex)].nameToken)
    if tokenIndex < 0 or tokenIndex >= index.parsed.tokens.len:
      return false
    if visibility == fieldsExported and
        fields[int(fieldIndex)].visibility != objectFieldExported:
      continue
    let token = index.parsed.tokens[tokenIndex]
    if not appendCompletionCandidate(
      index.parsed.tokens.tokenText(token),
      completionField,
      prefixKey,
      candidates,
      candidateByName,
    ):
      return false
  true
