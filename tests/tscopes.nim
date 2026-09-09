import std/unittest

import onim/index/scopes
import onim/index/scope_queries
import onim/index/scope_validation
import onim/index/scope_uncertainty
import onim/index/source_index
import onim/syntax/tokens

proc declarationNames(index: SourceIndex): seq[string] =
  for declaration in index.scopes.declarations:
    result.add index.parsed.tokens.tokenText(
      index.parsed.tokens[int(declaration.nameToken)]
    )

proc tokenNamed(index: SourceIndex, wanted: string): uint32 =
  for tokenIndex, token in index.parsed.tokens:
    if index.parsed.tokens.tokenTextEquals(token, wanted):
      return uint32(tokenIndex)
  high(uint32)

suite "native lexical scopes":
  test "always publishes a valid module scope":
    let index = indexSource("")
    check index.scopes.scopes.len == 1
    check index.scopes.validateScopes(index.parsed.tokens, index.symbols, 0)
    check index.scopes.innermostScopeAt(0) == InvalidScopeId
    check index.scopes.isComplete

  test "indexes routine parameters and direct locals":
    let source = """proc add(a, b: int; scale = 1): int =
  let total = a + b
  var resultValue: int
  const label = "sum"
  total
"""
    let index = indexSource(source)
    check index.scopes.validateScopes(index.parsed.tokens, index.symbols, source.len)
    check index.scopes.scopes.len == 2
    check declarationNames(index) ==
      @["a", "b", "scale", "total", "resultValue", "label"]
    check index.scopes.declarations[0].kind == declarationParameter
    check index.scopes.declarations[3].kind == declarationLet
    check index.scopes.declarations[4].kind == declarationVar
    check index.scopes.declarations[5].kind == declarationConst
    check index.scopes.innermostScopeAt(index.tokenNamed("total")) == ScopeId(2)
    check index.scopes.isComplete

  test "keeps multiline delimited locals inside their routine":
    let source = """proc show() =
  let point = (
    x: 1,
    y: 2
  )
  let values = [
    1,
    2
  ]
  let resultValue = combine(
1
  )
  echo point
  echo values
  echo resultValue
"""
    let index = indexSource(source)
    check index.scopes.validateScopes(index.parsed.tokens, index.symbols, source.len)
    check declarationNames(index) == @["point", "values", "resultValue"]
    check index.scopes.scopes.len == 2
    check index.scopes.isComplete

  test "keeps a same-line routine body through multiline delimiters":
    let source = """proc show() = echo combine(
1
)
proc next() = discard
"""
    let index = indexSource(source)
    check index.scopes.validateScopes(index.parsed.tokens, index.symbols, source.len)
    check index.scopes.scopes.len == 3
    check index.scopes.isComplete

  test "rejects an unclosed multiline declaration conservatively":
    let source = """proc show() =
  let value = combine(
    1
  echo value
"""
    let index = indexSource(source)
    check scopeMalformed in index.scopes.uncertainty
    check not index.scopes.isComplete

  test "keeps routine scopes and same-name locals distinct":
    let source = """proc first(value: int) =
  let local = value
  local
proc second(value: int) =
  let local = value
  local
"""
    let index = indexSource(source)
    check index.scopes.validateScopes(index.parsed.tokens, index.symbols, source.len)
    check index.scopes.scopes.len == 3
    check index.scopes.declarations.len == 4
    check index.scopes.declarations[1].scope != index.scopes.declarations[3].scope
    check index.scopes.scopes[1].ownerSymbol != index.scopes.scopes[2].ownerSymbol

  test "records declaration order without guessing binding":
    let source = """proc useLater() =
  useName()
  let useName = 1
  useName()
"""
    let index = indexSource(source)
    let declaration = index.scopes.declarations[0].nameToken
    var uses: seq[uint32] = @[]
    for tokenIndex, token in index.parsed.tokens:
      if index.parsed.tokens.tokenTextEquals(token, "useName") and
          uint32(tokenIndex) != declaration:
        uses.add uint32(tokenIndex)
    check uses.len == 2
    check uses[0] < declaration
    check declaration < uses[1]

  test "declines forward, generic, and nested-block guesses":
    let forward = indexSource("proc forward(value: int)\n")
    check forward.scopes.scopes.len == 1
    check forward.scopes.declarations.len == 0

    let generic = indexSource("proc generic[T](value: T) = discard\n")
    check generic.scopes.scopes.len == 1
    check scopeUnsupportedHeader in generic.scopes.uncertainty

    let genericReturn = indexSource(
      """type Box[T] = object
  value: T
proc makeBox(): Box[int] = discard
"""
    )
    check scopeUnsupportedHeader notin genericReturn.scopes.uncertainty
    check genericReturn.nativeIndexSafe()

    let noParameters = indexSource("proc noParameters = discard\n")
    check noParameters.scopes.scopes.len == 1
    check scopeUnsupportedHeader in noParameters.scopes.uncertainty

    let nested = indexSource(
      """proc nested() =
  if ready:
    let local = 1
  local
"""
    )
    check nested.scopes.declarations.len == 0
    check scopeNestedBlock in nested.scopes.uncertainty
    check not nested.scopes.isComplete

  test "models unnamed block lifetime and nesting":
    let source = """proc nested() =
  block:
    let local = 1
    echo local
  echo local
"""
    let index = indexSource(source)
    check index.scopes.validateScopes(index.parsed.tokens, index.symbols, source.len)
    check index.scopes.scopes.len == 3
    check index.scopes.scopes[2].kind == scopeBlock
    let local = index.tokenNamed("local")
    check index.scopes.innermostScopeAt(local) == ScopeId(3)
    let after = uint32(index.parsed.tokens.len - 1)
    check index.scopes.innermostScopeAt(after) == ScopeId(2)
    check index.scopes.isScopeAncestor(ScopeId(2), ScopeId(3))
    check not index.scopes.isScopeAncestor(ScopeId(3), ScopeId(2))
    check index.scopes.isComplete

  test "parents nested blocks and indexes each block's locals":
    let source = """proc nested() =
  block:
    let outer = 1
    block:
      let inner = outer
      echo inner
    echo outer
"""
    let index = indexSource(source)
    check index.scopes.validateScopes(index.parsed.tokens, index.symbols, source.len)
    check index.scopes.scopes.len == 4
    check index.scopes.scopes[2].kind == scopeBlock
    check index.scopes.scopes[3].kind == scopeBlock
    check index.scopes.scopes[3].parent == ScopeId(3)
    check declarationNames(index) == @["outer", "inner"]
    check index.scopes.isComplete

  test "marks malformed delimiters without reading source bytes":
    let malformed = indexSource("\"\"\"not closed\n")
    check scopeMalformed in malformed.scopes.uncertainty
    check not malformed.scopes.isComplete

  test "rejection of invalid intervals and declaration order":
    let index = indexSource("proc valid() = discard\n")
    var invalid = index.scopes
    invalid.scopes[1].parent = InvalidScopeId
    check not invalid.validateScopes(index.parsed.tokens, index.symbols, 25)

    var invalidDeclaration = index.scopes
    invalidDeclaration.declarations.add LexicalDeclaration(
      scope: ScopeId(2), kind: declarationLet, nameToken: 1, firstToken: 1, pastToken: 2
    )
    invalidDeclaration.declarations.add invalidDeclaration.declarations[^1]
    check not invalidDeclaration.validateScopes(
      index.parsed.tokens, index.symbols, index.byteLength
    )
