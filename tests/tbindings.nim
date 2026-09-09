import std/[os, unittest]

import onim/index/cache
import onim/index/bindings
import onim/index/scopes
import onim/index/source_index
import onim/syntax/parser
import onim/syntax/tokens

suite "native lexical bindings":
  test "uses inner blocks for shadowing and restores the parent":
    let source = """proc show(value: int) =
  block:
    let value = 1
    echo value
  echo value
"""
    let index = indexSource(source)
    var values: seq[uint32] = @[]
    for tokenIndex, token in index.parsed.tokens:
      if index.parsed.tokens.tokenTextEquals(token, "value"):
        values.add uint32(tokenIndex)
    check values.len == 4
    check index.resolveBinding(values[0]).state == bindingResolved
    check index.resolveBinding(values[0]).declarationToken == values[0]
    check index.resolveBinding(values[1]).declarationToken == values[1]
    check index.resolveBinding(values[2]).declarationToken == values[1]
    check index.resolveBinding(values[3]).declarationToken == values[0]

  test "does not guess a declaration before it exists":
    let source = """proc ordered() =
  echo value
  let value = 1
  echo value
"""
    let index = indexSource(source)
    var values: seq[uint32] = @[]
    for tokenIndex, token in index.parsed.tokens:
      if index.parsed.tokens.tokenTextEquals(token, "value"):
        values.add uint32(tokenIndex)
    check values.len == 3
    check index.resolveBinding(values[0]).state == bindingUnknown
    check index.resolveBinding(values[1]).state == bindingResolved
    check index.resolveBinding(values[2]).declarationToken == values[1]

  test "reconstructs syntax and bindings from a cached index":
    let projectRoot = getTempDir() / ("onim-binding-cache-" & $getCurrentProcessId())
    let modulePath = projectRoot / "src" / "main.nim"
    let source = """proc main(value: int) =
  block:
    let inner = value
    echo inner
"""
    let index = indexSource(source)
    let previous = getEnv("ONIM_CACHE_DIR")
    putEnv("ONIM_CACHE_DIR", projectRoot / "cache")
    check saveCachedSourceIndex(projectRoot, modulePath, source, index)
    let cached = loadCachedSourceIndex(projectRoot, modulePath, source)
    check cached != nil
    check cached.syntax.validateSyntaxTree
    check cached.syntax.nodes == index.syntax.nodes
    check cached.scopes.scopes == index.scopes.scopes
    check cached.scopes.declarations == index.scopes.declarations
    check cached.resolveBinding(cached.parsed.tokens.high.uint32).state ==
      bindingResolved
    check cached.resolveBinding(cached.parsed.tokens.high.uint32).declarationToken ==
      index.resolveBinding(index.parsed.tokens.high.uint32).declarationToken
    if previous.len > 0:
      putEnv("ONIM_CACHE_DIR", previous)
    else:
      delEnv("ONIM_CACHE_DIR")
