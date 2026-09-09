import std/sets

import ./tokens

proc collectDefinitions*(tokens: TokenStore): HashSet[string] =
  result = initHashSet[string]()
  for index, token in tokens:
    if token.kind != tkIdentifier:
      continue
    if token.hasKeywordRole(roleRoutine):
      var cursor = index + 1
      if cursor < tokens.len and tokens.tokenTextEquals(tokens[cursor], "*"):
        inc cursor
      if cursor < tokens.len and tokens[cursor].kind == tkIdentifier:
        result.incl tokens.tokenText(tokens[cursor])
    elif token.hasKeywordRole(roleTypeDeclaration):
      var cursor = index + 1
      let declarationLine =
        if cursor < tokens.len:
          tokens[cursor].line
        else:
          token.line
      while cursor < tokens.len and tokens[cursor].line == declarationLine and
          not tokens.tokenTextEquals(tokens[cursor], "=") and
          not tokens.tokenTextEquals(tokens[cursor], ";")
      :
        if tokens[cursor].kind == tkIdentifier:
          result.incl tokens.tokenText(tokens[cursor])
          break
        inc cursor
    elif token.hasKeywordRole(roleValueDeclaration):
      var cursor = index + 1
      let declarationLine =
        if cursor < tokens.len:
          tokens[cursor].line
        else:
          token.line
      while cursor < tokens.len and tokens[cursor].line == declarationLine and
          not tokens.tokenTextEquals(tokens[cursor], ":") and
          not tokens.tokenTextEquals(tokens[cursor], "=") and
          not tokens.tokenTextEquals(tokens[cursor], ";")
      :
        if tokens[cursor].kind == tkIdentifier:
          result.incl tokens.tokenText(tokens[cursor])
        inc cursor
    elif token.hasKeywordRole(roleForBinding):
      var cursor = index + 1
      while cursor < tokens.len and not tokens.tokenTextEquals(tokens[cursor], "in") and
          not tokens.tokenTextEquals(tokens[cursor], "=") and
          not tokens.tokenTextEquals(tokens[cursor], ":")
      :
        if tokens[cursor].kind == tkIdentifier:
          result.incl tokens.tokenText(tokens[cursor])
        inc cursor
    elif token.hasKeywordRole(roleBindDeclaration):
      var cursor = index + 1
      if cursor < tokens.len and tokens[cursor].kind == tkIdentifier:
        result.incl tokens.tokenText(tokens[cursor])
