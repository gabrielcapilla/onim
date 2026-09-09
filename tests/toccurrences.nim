import std/unittest

import onim/index/occurrences
import onim/index/source_index
import onim/index/symbols
import onim/syntax/tokens
import onim/syntax/lexer

proc names(index: SourceIndex): seq[string] =
  for occurrence in index.occurrences.identifiers:
    result.add index.parsed.tokens.tokenText(index.parsed.tokens[int(occurrence.token)])

proc hasRole(roles: set[OccurrenceRole], role: OccurrenceRole): bool =
  role in roles

suite "native identifier occurrences":
  test "classifies keywords once at the lexer boundary":
    check keywordId("proc") == kwProc
    check roleRoutine in keywordRoles(kwProc)
    check roleDeclaration in keywordRoles(kwProc)
    check keywordId("notAKeyword") == kwNone

    let tokens = lex("proc run() = discard\n`proc`()")
    check tokens[0].keyword == kwProc
    check tokens[6].keyword == kwNone
    check not tokens[6].isNimKeyword

  test "uses numeric source order and Nim identifier style":
    let index = indexSource("let Foo_Bar = 1\nFooBar()\nfooBar()\n")
    check index.occurrences.validateOccurrences(index.parsed.tokens)
    check names(index) == @["FooBar", "fooBar"]
    check index.occurrences.usage.len == 2
    check index.occurrences.usageFor(index.parsed.tokens, "Foo_Bar").referenceCount == 1
    check index.occurrences.usageFor(index.parsed.tokens, "FooBar").referenceCount == 1
    check index.occurrences.usageFor(index.parsed.tokens, "fooBar").referenceCount == 1
    check sameIdentifier("Foo_Bar", "FooBar")
    check not sameIdentifier("Foo_Bar", "fooBar")

  test "records qualified chains and role counts":
    let index = indexSource("a . b . c\n")
    check index.occurrences.validateOccurrences(index.parsed.tokens)
    check index.occurrences.qualified.len == 2
    let middle = index.occurrences.usageFor(index.parsed.tokens, "b")
    check middle.referenceCount == 1
    check middle.qualifierCount == 1
    check middle.memberCount == 1
    let first = index.occurrences.identifiers[0]
    check first.roles.hasRole(occurrenceQualifier)
    check not first.roles.hasRole(occurrenceMember)
    let last = index.occurrences.identifiers[^1]
    check last.roles.hasRole(occurrenceMember)
    check not last.roles.hasRole(occurrenceQualifier)

  test "does not count comments strings imports or declaration names":
    let source = """# walkDir parseJson split
import std/[os, json]
from std/strutils import split
proc local() = discard
let text = "walkDir parseJson split"
walkDir("/tmp")
"""
    let index = indexSource(source)
    check index.occurrences.validateOccurrences(index.parsed.tokens)
    check names(index) == @["walkDir"]
    check index.occurrences.hasUsage(index.parsed.tokens, "walkDir")
    check not index.occurrences.hasUsage(index.parsed.tokens, "parseJson")
    check not index.occurrences.hasUsage(index.parsed.tokens, "split")
    check not index.occurrences.hasUsage(index.parsed.tokens, "local")
    check not index.occurrences.hasUsage(index.parsed.tokens, "text")

  test "records conservative uncertainty reasons":
    let source = """when defined(posix):
  echo generatedName
include "parts"
macro make() = discard
"""
    let occurrences = indexSource(source).occurrences
    check uncertaintyConditional in occurrences.uncertainty
    check uncertaintyNestedScope in occurrences.uncertainty
    check uncertaintyInclude in occurrences.uncertainty
    check uncertaintyGenerated in occurrences.uncertainty
    check uncertaintyUnsupportedSyntax in occurrences.uncertainty
    check not occurrences.isComplete

  test "keeps stropped identifiers and rejects malformed spans":
    let index = indexSource("`proc`()\n`broken\n")
    check index.occurrences.hasUsage(index.parsed.tokens, "proc")
    check uncertaintyMalformed in index.occurrences.uncertainty
    check not index.occurrences.isComplete
