import std/[os, strutils, unittest]

import onim/index/source_index
import onim/syntax/imports
import onim/syntax/lexer
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
  test "preserves source-backed lexical spans and lexical boundaries":
    let source =
      "\xEF\xBB\xBF# commentName\n" & "let normal_name = `strange-name`\n" &
      "let empty = ``\n" &
      "echo \"stringName\" \"\"\"tripleName\"\"\" r\"rawName\" ( [ ] )\n" &
      "let café = 1\n" & "let ratio = 3.14\n" & "let broken = `unterminated\n"
    let tokens = lex(source)
    var normal = false
    var closedStrop = false
    var emptyStrop = false
    var openStrop = false
    var closedStrings = 0
    var delimiters = 0
    var numericTokens = 0
    for token in tokens:
      if tokens.tokenTextEquals(token, "normal_name"):
        normal = token.kind == tkIdentifier and token.validIdentifier
      elif token.isStropped:
        if tfClosed in token.flags:
          if tokens.tokenTextEquals(token, "strange-name"):
            closedStrop = true
          elif tokens.tokenTextLen(token) == 0:
            emptyStrop = not token.validIdentifier
        else:
          openStrop = not token.validIdentifier
      elif token.kind == tkString and token.isClosedString:
        inc closedStrings
      elif token.kind == tkNumber:
        inc numericTokens
        check tokens.tokenTextLen(token) > 0
      if token.kind == tkPunctuation and (
        tokens.tokenTextEquals(token, "(") or tokens.tokenTextEquals(token, "[") or
        tokens.tokenTextEquals(token, "]") or tokens.tokenTextEquals(token, ")")
      ):
        inc delimiters
      check not tokens.tokenTextEquals(token, "commentName")
      check not tokens.tokenTextEquals(token, "stringName")
      check not tokens.tokenTextEquals(token, "rawName")
    check tokens.len > 0
    check tokens[0].line == 1
    check tokens[0].column == 0
    check tokens[0].startOffset == source.find("let normal_name")
    check normal
    check closedStrop
    check emptyStrop
    check openStrop
    check closedStrings == 2
    check delimiters == 4
    check numericTokens == 2

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
    check not tree.isComplete
    check parserUnsupportedStructure in tree.uncertainty
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

  test "keeps supported numeric suffixes in one token":
    let source =
      "let byteValue = 1'u8\n" & "let signedValue = 2'i32\n" & "let ratio = 3.0'f32\n" &
      "let hexadecimal = 0x10'u16\n"
    let tokens = lex(source)
    var numericTexts: seq[string] = @[]
    for token in tokens:
      if token.kind == tkNumber:
        numericTexts.add tokens.tokenText(token)
    check numericTexts == @["1'u8", "2'i32", "3.0'f32", "0x10'u16"]
    check lexicalIssues(tokens).len == 0

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
    check countNodes(named, syntaxBlock) == 1
    check parserUnsupportedStructure in named.uncertainty

  test "bounds incomplete imports without phantom dependencies":
    let source = "import goodA\nimport pkg/[part,\nimport goodB\n"
    let tree = parsePartialSyntax(source)
    let imports = parseSourceImports(source)
    check tree.validateSyntaxTree
    check not tree.isComplete
    check parserIncomplete in tree.uncertainty
    check tree.importNodes.len == 3
    let middle = tree.nodes[int(uint32(tree.importNodes[1])) - 1]
    check middle.kind == syntaxImport
    check parserIncomplete in middle.uncertainty
    check tree.nodes[int(uint32(tree.importNodes[0])) - 1].uncertainty == {}
    check tree.nodes[int(uint32(tree.importNodes[2])) - 1].uncertainty == {}
    check imports.imports.len == 2
    check imports.imports[0].module == "goodA"
    check imports.imports[1].module == "goodB"
    check tree.importsMatch(imports)

  test "matches every checked-in import fixture":
    let root = currentSourcePath().parentDir.parentDir / "tests" / "before"
    for path in walkDirRec(root):
      if not path.endsWith(".nim"):
        continue
      let source = readFile(path)
      let tree = parsePartialSyntax(source)
      check tree.validateSyntaxTree
      check tree.importsMatch(parseSourceImports(source))
