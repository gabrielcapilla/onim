import std/unittest

import onim/index/source_index
import onim/index/symbols

proc symbolNames(index: SourceIndex): seq[string] =
  for symbol in index.symbols:
    result.add index.parsed.tokens[int(symbol.nameToken)].text

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
