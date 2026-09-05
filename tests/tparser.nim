import std/[os, strutils, unittest]

import onim/index/source_index
import onim/syntax/imports
import onim/syntax/parser

proc countNodes(tree: PartialSyntaxTree, kind: SyntaxNodeKind): int =
  for node in tree.nodes:
    if node.kind == kind:
      inc result

proc childOf(tree: PartialSyntaxTree, kind, parentKind: SyntaxNodeKind): bool =
  for node in tree.nodes:
    if node.kind != kind or uint32(node.parent) == 0'u32:
      continue
    let parentIndex = int(uint32(node.parent)) - 1
    if parentIndex >= 0 and parentIndex < tree.nodes.len and
        tree.nodes[parentIndex].kind == parentKind:
      return true

suite "recoverable native syntax tree":
  test "records imports and structural containers without duplicating lexer data":
    let source = """# header
import std/[os, strformat]
from std/json import parseJson as parse
when defined(posix):
  import std/tables except newTable
include "shared"
export std/os

proc main(value: int) =
  value
"""
    let tree = parsePartialSyntax(source)
    let imports = parseSourceImports(source)
    check tree.validateSyntaxTree
    check tree.importsMatch(imports)
    check tree.isComplete
    let indexed = indexSource(source)
    check indexed.syntax.validateSyntaxTree
    check indexed.syntax.importsMatch(indexed.parsed)
    check countNodes(tree, syntaxImport) == 2
    check countNodes(tree, syntaxFromImport) == 1
    check countNodes(tree, syntaxWhen) == 1
    check countNodes(tree, syntaxInclude) == 1
    check countNodes(tree, syntaxExport) == 1
    check countNodes(tree, syntaxDeclaration) == 1
    check childOf(tree, syntaxImport, syntaxWhen)

  test "recovers from malformed lexical structure":
    let unclosedString = parsePartialSyntax("echo \"not closed\n")
    check unclosedString.validateSyntaxTree
    check parserMalformed in unclosedString.uncertainty
    check not unclosedString.isComplete

    let unbalanced = parsePartialSyntax("let value = (1\n")
    check unbalanced.validateSyntaxTree
    check parserUnbalanced in unbalanced.uncertainty
    check not unbalanced.isComplete

  test "records unnamed block containers":
    let tree = parsePartialSyntax(
      """proc main() =
  block:
    let value = 1
    echo value
  echo value
"""
    )
    check tree.validateSyntaxTree
    check countNodes(tree, syntaxBlock) == 1
    check childOf(tree, syntaxBlock, syntaxDeclaration)

    let named = parsePartialSyntax("proc main() =\n  block label:\n    discard\n")
    check countNodes(named, syntaxBlock) == 0
    check parserUnsupportedStructure in named.uncertainty

  test "matches every checked-in import fixture":
    let root = currentSourcePath().parentDir.parentDir / "tests" / "before"
    for path in walkDirRec(root):
      if not path.endsWith(".nim"):
        continue
      let source = readFile(path)
      let tree = parsePartialSyntax(source)
      check tree.validateSyntaxTree
      check tree.importsMatch(parseSourceImports(source))
