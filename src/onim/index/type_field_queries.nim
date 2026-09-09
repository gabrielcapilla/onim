import ./types
import ./type_index_models

proc objectFieldOrdinal*(index: TypeIndex, nameToken: uint32): int {.inline.} =
  var first = 0
  var past = index.fields.len
  while first < past:
    let middle = (first + past) div 2
    let candidate = index.fields[middle].nameToken
    if candidate < nameToken:
      first = middle + 1
    elif candidate > nameToken:
      past = middle
    else:
      return middle
  -1

proc objectFieldExportMarker*(index: TypeIndex, tokenIndex: uint32): bool {.inline.} =
  if tokenIndex == 0:
    return false
  let ordinal = index.objectFieldOrdinal(tokenIndex - 1'u32)
  ordinal >= 0 and index.fields[ordinal].visibility == objectFieldExported
