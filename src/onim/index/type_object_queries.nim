import ../syntax/tokens
import ./symbols
import ./type_declaration_syntax
import ./type_index_models
import ./type_queries

proc objectOrdinal*(index: TypeIndex, declarationToken: uint32): int {.inline.} =
  var first = 0
  var past = index.objects.len
  while first < past:
    let middle = (first + past) div 2
    let candidate = index.objects[middle].declarationToken
    if candidate < declarationToken:
      first = middle + 1
    elif candidate > declarationToken:
      past = middle
    else:
      return middle
  -1

proc objectOrdinalForType*(
    index: TypeIndex,
    tokens: TokenStore,
    symbols: openArray[SourceSymbol],
    typeToken: uint32,
): int =
  if typeToken == InvalidTypeToken or not validNameToken(tokens, int(typeToken)):
    return -1
  let wanted = identifierKey(tokens, tokens[int(typeToken)])
  var found = -1
  var matches = 0
  for symbol in symbols:
    if symbol.kind != symbolType or symbol.nameToken >= uint32(tokens.len):
      continue
    if identifierKey(tokens, tokens[int(symbol.nameToken)]) != wanted:
      continue
    inc matches
    let ordinal = index.objectOrdinal(symbol.nameToken)
    if ordinal < 0:
      return -1
    found = ordinal
  if matches == 1: found else: -1

proc localTupleObjectOrdinal*(
    index: TypeIndex, declarationToken: uint32
): int {.inline.} =
  var first = 0
  var past = index.localTupleObjects.len
  while first < past:
    let middle = (first + past) div 2
    let candidate = index.localTupleObjects[middle].declarationToken
    if candidate < declarationToken:
      first = middle + 1
    elif candidate > declarationToken:
      past = middle
    else:
      return middle
  -1
