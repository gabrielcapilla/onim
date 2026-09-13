import std/unittest

import onim/index/source_index
import onim/index/scopes
import onim/index/symbols
import onim/index/type_ids
import onim/index/type_index_validation
import onim/index/type_kinds
import onim/index/type_local_models
import onim/index/type_local_resolution
import onim/index/type_queries
import onim/index/type_routine_returns
import onim/index/type_states
import onim/syntax/tokens

proc symbolNames(index: SourceIndex): seq[string] =
  for symbol in index.symbols:
    result.add index.parsed.tokens.tokenText(index.parsed.tokens[int(symbol.nameToken)])

suite "native source symbols":
  test "indexes module declarations in source order":
    let source = """type
  Foo* = object
    field: int
  Bar = enum
    member
var
  count*, total: int
let ready = true
const answer = 42
proc first*() = discard
func second() = discard
iterator values() = discard
method dispatch() = discard
macro build() = discard
template inline() = discard
converter convert() = discard
"""
    let index = indexSource(source)
    check symbolNames(index) ==
      @[
        "Foo", "Bar", "count", "total", "ready", "answer", "first", "second", "values",
        "dispatch", "build", "inline", "convert",
      ]
    check index.symbols[0].kind == symbolType
    check index.symbols[0].exported
    check index.symbols[2].kind == symbolVar
    check index.symbols[3].kind == symbolVar
    check index.symbols[6].kind == symbolProc
    check index.symbols[7].kind == symbolFunc
    check index.symbols[8].kind == symbolIterator
    check index.symbols[9].kind == symbolMethod
    check index.symbols[10].kind == symbolMacro
    check index.symbols[11].kind == symbolTemplate
    check index.symbols[12].kind == symbolConverter

  test "scopes field duplicate checks to one declaration":
    let index = indexSource(
      "type First = object\n" & "  value: int\n" & "type Second = object\n" &
        "  value: string\n" & "type Invalid = object\n" & "  value: int\n" &
        "  value_: string\n"
    )
    check index.types.objects.len == 2
    check index.types.fields.len == 2
    for objectType in index.types.objects:
      check objectType.pastField - objectType.firstField == 1'u32
      check index.parsed.tokens.tokenText(
        index.parsed.tokens[
          int(index.types.fields[int(objectType.firstField)].nameToken)
        ]
      ) == "value"
    check validateTypeIndex(
      index.types, index.parsed.tokens, index.symbols, index.scopes
    )

  test "ignores nested fields, conditionals, comments, strings, and backticked keywords":
    let source = """# proc fake() = discard
let text = "proc alsoFake() = discard"
when defined(posix):
  proc conditional() = discard
type
  Payload = object
    procField: int
    case kind: bool
    of true:
      yesField: int
proc `proc`() = discard
`proc` fake() = discard
"""
    let index = indexSource(source)
    check symbolNames(index) == @["text", "Payload", "proc"]

  test "matches Nim identifier style and declines overload ambiguity":
    let unique = indexSource("proc Foo_Bar() = discard\n")
    check sameIdentifier("Foo_Bar", "FooBar")
    check not sameIdentifier("Foo_Bar", "fooBar")
    check lookupSymbol(unique.symbols, unique.parsed.tokens, "FooBar") == 0

    let overloaded = indexSource("proc run() = discard\nproc run() = discard\n")
    check overloaded.symbols.len == 2
    check lookupSymbol(overloaded.symbols, overloaded.parsed.tokens, "run") == -1

  test "stores exact declaration token spans":
    let source = "proc hello*() = discard\n"
    let index = indexSource(source)
    check index.symbols.len == 1
    let token = index.parsed.tokens[int(index.symbols[0].nameToken)]
    check source[token.startOffset ..< token.endOffset] == "hello"
    check token.line == 0
    check token.column == 5

  test "aligns and validates routine return anchors":
    let index = indexSource(
      """proc make*(): int = 1
func text(): string = "ok"
proc inferred() = discard
proc generic[T](): int = 1
"""
    )
    check index.types.routineReturnTypeIds.len == index.symbols.len
    check index.types.routineReturnTypeIds[0].valid
    check index.types.routineReturnTypeIds[1].valid
    check not index.types.routineReturnTypeIds[2].valid
    check not index.types.routineReturnTypeIds[3].valid
    check index.types.typeKind(index.types.routineReturnTypeIds[0]) == typeInt
    check index.types.typeKind(index.types.routineReturnTypeIds[1]) == typeString
    check validateTypeIndex(
      index.types, index.parsed.tokens, index.symbols, index.scopes
    )
    var corrupted = index.types
    corrupted.routineReturnTypeIds[0] = TypeId(999'u32)
    check not validateTypeIndex(
      corrupted, index.parsed.tokens, index.symbols, index.scopes
    )

  test "indexes unary generic objects and explicit instances":
    let index = indexSource(
      """type Box[T] = object
  value: T

proc makeBox(): Box[int] =
  Box[int](value: 1)

proc use(box: Box[int]) =
  discard box.value
"""
    )
    check index.types.objects.len == 1
    check index.types.objects[0].pastGenericParameter -
      index.types.objects[0].firstGenericParameter == 1'u32
    let parameterToken = index.types.genericParameterTokens[0]
    check index.parsed.tokens.tokenText(index.parsed.tokens[int(parameterToken)]) == "T"
    var boxToken = InvalidTypeToken
    for declaration in index.scopes.declarations:
      if index.parsed.tokens.tokenText(index.parsed.tokens[int(declaration.nameToken)]) ==
          "box":
        boxToken = declaration.nameToken
    check boxToken != InvalidTypeToken
    let local = index.types.localTypeAt(index.parsed.tokens, index.scopes, boxToken)
    check local.state == typeStateResolved
    check local.kind == typeGenericInstance
    check index.types.typeKind(index.types.typeBase(local.typeId)) == typeInt
    var makeBoxOrdinal = -1
    for symbolIndex, symbol in index.symbols:
      if index.parsed.tokens.tokenText(index.parsed.tokens[int(symbol.nameToken)]) ==
          "makeBox":
        makeBoxOrdinal = symbolIndex
    check makeBoxOrdinal >= 0
    let returned =
      index.types.routineReturnAt(index.parsed.tokens, index.symbols, makeBoxOrdinal)
    check returned.state == typeStateResolved
    check returned.kind == typeGenericInstance
    check index.types.typeKind(index.types.typeBase(returned.typeId)) == typeInt
    check validateTypeIndex(
      index.types, index.parsed.tokens, index.symbols, index.scopes
    )

  test "indexes explicit primitive sequence annotations":
    let index = indexSource(
      """proc show() =
  let first: seq[int] = @[]
  let second: seq[int] = @[1]
  discard first
  discard second
"""
    )
    var declarations: seq[uint32] = @[]
    for declaration in index.scopes.declarations:
      let token = index.parsed.tokens[int(declaration.nameToken)]
      if index.parsed.tokens.tokenTextEquals(token, "first") or
          index.parsed.tokens.tokenTextEquals(token, "second"):
        declarations.add declaration.nameToken
    check declarations.len == 2
    for declarationToken in declarations:
      let info =
        index.types.localTypeAt(index.parsed.tokens, index.scopes, declarationToken)
      check info.form == localTypeFormAnnotation
      check info.state == typeStateResolved
      check info.kind == typeSeq
      check index.types.typeKind(index.types.typeBase(info.typeId)) == typeInt
    check index.types.records.len == 6
    check validateTypeIndex(
      index.types, index.parsed.tokens, index.symbols, index.scopes
    )

  test "indexes bounded primitive array annotations":
    let index = indexSource(
      """proc show() =
  let empty: array[0, int] = default(array[0, int])
  let emptyAgain: array[0, int] = default(array[0, int])
  let flags: array[4, bool] = default(array[4, bool])
  let text: array[8, string] = default(array[8, string])
  let letters: array[2, char] = default(array[2, char])
  let ratios: array[3, float] = default(array[3, float])
  let duplicate: array[4, bool] = default(array[4, bool])
  let other: array[5, int] = default(array[5, int])
  let overflow: array[4294967296, int] = default(array[0, int])
  let nested: array[2, seq[int]] = default(array[0, int])
"""
    )
    var infos: seq[LocalTypeInfo] = @[]
    for declaration in index.scopes.declarations:
      let name =
        index.parsed.tokens.tokenText(index.parsed.tokens[int(declaration.nameToken)])
      if name in [
        "empty", "emptyAgain", "flags", "text", "letters", "ratios", "duplicate",
        "other",
      ]:
        infos.add index.types.localTypeAt(
          index.parsed.tokens, index.scopes, declaration.nameToken
        )
    check infos.len == 8
    for info in infos:
      check info.form == localTypeFormAnnotation
      check info.state == typeStateResolved
      check info.kind == typeArray
      check index.types.typeKind(index.types.typeBase(info.typeId)) in
        {typeBool, typeChar, typeString, typeInt, typeFloat}
    check infos[0].typeId == infos[1].typeId
    check infos[2].typeId == infos[6].typeId
    check infos[0].typeId != infos[7].typeId
    check index.types.records[int(uint32(infos[0].typeId)) - 1].extent == 0'u32
    check index.types.records[int(uint32(infos[2].typeId)) - 1].extent == 4'u32
    check not index.types.localTypeAt(
      index.parsed.tokens, index.scopes, index.scopes.declarations[^2].nameToken
    ).typeId.valid
    check not index.types.localTypeAt(
      index.parsed.tokens, index.scopes, index.scopes.declarations[^1].nameToken
    ).typeId.valid
    check validateTypeIndex(
      index.types, index.parsed.tokens, index.symbols, index.scopes
    )
    var missingBase = index.types
    missingBase.records[int(uint32(infos[2].typeId)) - 1].baseType = InvalidTypeId
    check not validateTypeIndex(
      missingBase, index.parsed.tokens, index.symbols, index.scopes
    )
    var duplicate = index.types
    duplicate.records.add duplicate.records[int(uint32(infos[2].typeId)) - 1]
    check not validateTypeIndex(
      duplicate, index.parsed.tokens, index.symbols, index.scopes
    )

  test "indexes array parameters and routine returns":
    let index = indexSource(
      """proc make(): array[3, float] = default(array[3, float])
proc show(values: array[6, char]) =
  discard values
"""
    )
    var valuesToken = InvalidTypeToken
    for declaration in index.scopes.declarations:
      let token = index.parsed.tokens[int(declaration.nameToken)]
      if index.parsed.tokens.tokenTextEquals(token, "values"):
        valuesToken = declaration.nameToken
    check valuesToken != InvalidTypeToken
    let parameter =
      index.types.localTypeAt(index.parsed.tokens, index.scopes, valuesToken)
    check parameter.state == typeStateResolved
    check parameter.kind == typeArray
    check index.types.records[int(uint32(parameter.typeId)) - 1].extent == 6'u32
    let makeOrdinal = lookupSymbol(index.symbols, index.parsed.tokens, "make")
    check makeOrdinal >= 0
    let returned =
      index.types.routineReturnAt(index.parsed.tokens, index.symbols, makeOrdinal)
    check returned.state == typeStateResolved
    check returned.kind == typeArray
    check index.types.records[int(uint32(returned.typeId)) - 1].extent == 3'u32
    check validateTypeIndex(
      index.types, index.parsed.tokens, index.symbols, index.scopes
    )

  test "indexes exact first-parameter UFCS candidates":
    let index = indexSource(
      """proc numberText(value: int; radix: int) = discard
func textLength(value: string) = discard
proc noArgs() = discard
proc forward(value: int)
iterator values(value: int) = discard
method dispatch(value: int) = discard
"""
    )
    check index.types.ufcsProcedures.len == 3
    for candidateIndex, candidate in index.types.ufcsProcedures:
      check candidate.typeId.valid
      check candidate.parameterOrdinal < uint32(index.scopes.declarations.len)
      let parameter = index.scopes.declarations[int(candidate.parameterOrdinal)]
      check parameter.kind == declarationParameter
      check index.parsed.tokens.tokenText(index.parsed.tokens[int(parameter.nameToken)]) ==
        "value"
      let symbol = index.symbols[int(candidate.symbolOrdinal)]
      check symbol.kind in {symbolProc, symbolFunc, symbolMethod}
      check symbol.nameToken < parameter.nameToken
      if candidateIndex > 0:
        check uint32(candidate.typeId) >=
          uint32(index.types.ufcsProcedures[candidateIndex - 1].typeId)
    check validateTypeIndex(
      index.types, index.parsed.tokens, index.symbols, index.scopes
    )

  test "preserves reference wrappers for locals and routine returns":
    let index = indexSource(
      """type Person = object

proc make(): ref Person = discard
proc show(value: ref Person) =
  discard value
"""
    )
    var valueToken = InvalidTypeToken
    for declaration in index.scopes.declarations:
      let token = index.parsed.tokens[int(declaration.nameToken)]
      if index.parsed.tokens.tokenTextEquals(token, "value"):
        valueToken = declaration.nameToken
    check valueToken != InvalidTypeToken
    let local = index.types.localTypeAt(index.parsed.tokens, index.scopes, valueToken)
    check local.state == typeStateResolved
    check local.kind == typeRef
    check index.types.typeKind(index.types.typeBase(local.typeId)) == typeNamed
    check local.typeToken != InvalidTypeToken
    let makeOrdinal = lookupSymbol(index.symbols, index.parsed.tokens, "make")
    check makeOrdinal >= 0
    let returned =
      index.types.routineReturnAt(index.parsed.tokens, index.symbols, makeOrdinal)
    check returned.state == typeStateResolved
    check returned.kind == typeRef
    check index.types.namedTypeId(returned.typeId).valid
    check validateTypeIndex(
      index.types, index.parsed.tokens, index.symbols, index.scopes
    )
    var corrupted = index.types
    let wrapperOrdinal = int(uint32(local.typeId)) - 1
    corrupted.records[wrapperOrdinal].baseType = InvalidTypeId
    check not validateTypeIndex(
      corrupted, index.parsed.tokens, index.symbols, index.scopes
    )
