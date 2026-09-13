import std/[unittest]

import onim/index/source_index
import onim/semantic/native_diagnostics
import onim/syntax/parser

type SyntaxCase = tuple[name, source: string]

const validCases: array[8, SyntaxCase] = [
  (
    "declarations and literals",
    "const answer* = 42\n" & "let text = r\"raw\"\n" & "var enabled: bool\n" &
      "let byteValue = 99'u8\n" & "let ratio = 3.14'f32\n",
  ),
  (
    "generic routines and callbacks",
    "proc apply[T, U](value: T, f: proc(value: T): U): U =\n" & "  f(value)\n" &
      "iterator values[T](items: openArray[T]): T =\n" & "  for item in items:\n" &
      "    yield item\n",
  ),
  (
    "objects enums tuples and variants",
    "type\n" & "  Kind = enum nkValue, nkPair\n" & "  Pair = tuple[left, right: int]\n" &
      "  Node = object\n" & "    case kind: Kind\n" & "    of nkValue:\n" &
      "      value: int\n" & "    of nkPair:\n" & "      pair: Pair\n",
  ),
  (
    "imports conditionals includes and exports",
    "when defined(posix):\n" & "  import std/[os, strutils]\n" & "else:\n" &
      "  import std/winlean\n" & "include generated_part\n" & "export std/strutils\n",
  ),
  (
    "control flow and exception handling",
    "proc readValue(value: string): int {.raises: [ValueError].} =\n" & "  try:\n" &
      "    result = parseInt(value)\n" & "  except ValueError:\n" & "    result = 0\n" &
      "  finally:\n" & "    discard\n",
  ),
  (
    "blocks and operators",
    "proc compute(values: seq[int]): int =\n" & "  block done:\n" &
      "    for value in values:\n" & "      if value < 0:\n" & "        break done\n" &
      "      result += value\n" & "  result = -result\n",
  ),
  (
    "pragmas macros and quoted identifiers",
    "template inline(value: untyped): untyped = value\n" &
      "proc `type`*(value: int): int {.inline.} = value\n" &
      "macro emit(value: untyped): untyped =\n" & "  result = value\n",
  ),
  (
    "multiline expressions and strings",
    "let values = @[\n" & "  (name: \"first\", value: 1),\n" &
      "  (name: \"second\", value: 2),\n" & "]\n" &
      "let message = \"comments # and brackets ([)] stay text\"\n",
  ),
]

const incompleteCases: array[4, SyntaxCase] = [
  ("unfinished type", "proc main() =\n  var value: "),
  ("unfinished conditional", "when isMainModule:\n  "),
  ("unfinished import list", "import std/[os, "),
  ("unfinished delimiter", "let value = (1 + "),
]

suite "representative Nim syntax corpus":
  for item in validCases:
    test item.name:
      let index = indexSource(item.source)
      check index.syntax.validateSyntaxTree
      check index.syntax.importsMatch(index.parsed)
      check nativeSyntaxDiagnostics(index).len == 0

  for item in incompleteCases:
    test item.name:
      let index = indexSource(item.source)
      check index.syntax.validateSyntaxTree
      check index.syntax.importsMatch(index.parsed)

  test "preserves relative import prefixes":
    let index = indexSource("import ./models\nimport ../shared/types\n")
    check index.parsed.imports.len == 2
    check index.parsed.imports[0].module == "./models"
    check index.parsed.imports[1].module == "../shared/types"
    check index.imports == @["../shared/types", "./models"]
