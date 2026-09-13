import std/[sets, strutils]

import ../semantic/compiler_api
import ../stdlib/map
import ../syntax/imports
import ../syntax/tokens

proc findFromImport*(imports: SourceImports, module: string, name: string): int =
  for index, item in imports.imports:
    if item.synthetic or
        imports.conditionalImportDisposition(item) notin
        {importUnconditional, importConditionalActive}:
      continue
    if item.form == fromModule and item.alias.len == 0 and
        sameModule(item.module, module) and name notin item.imported:
      return index
  -1

proc findExistingModule*(
    imports: SourceImports, module: string
): tuple[plain, aliased, excluded: int] =
  result = (-1, -1, -1)
  for index, item in imports.imports:
    if item.synthetic or
        imports.conditionalImportDisposition(item) notin
        {importUnconditional, importConditionalActive}:
      continue
    if item.form != importModule or not sameModule(item.module, module):
      continue
    if item.alias.len > 0:
      result.aliased = index
    elif item.excluded.len > 0:
      result.excluded = index
    else:
      result.plain = index

proc findUsageToken*(info: SourceImports, diagnostic: CompilerDiagnostic): int =
  var best = -1
  var bestDistance = high(int)
  for index, token in info.tokens:
    if token.kind != tkIdentifier or
        not info.tokens.tokenTextEquals(token, diagnostic.name):
      continue
    let distance =
      abs(token.line - diagnostic.line) * 10000 + abs(token.column - diagnostic.column)
    if distance < bestDistance:
      best = index
      bestDistance = distance
  best

proc callArity*(info: SourceImports, source: string, tokenIndex: int): int =
  if tokenIndex < 0 or tokenIndex + 1 >= info.tokens.len or
      not info.tokens.tokenTextEquals(info.tokens[tokenIndex + 1], "("):
    return -1
  var depth = 0
  var commas = 0
  for index in tokenIndex + 1 ..< info.tokens.len:
    if info.tokens.tokenTextEquals(info.tokens[index], "("):
      inc depth
    elif info.tokens.tokenTextEquals(info.tokens[index], ")"):
      dec depth
      if depth == 0:
        let content =
          source[
            info.tokens[tokenIndex + 1].endOffset ..< info.tokens[index].startOffset
          ].strip
        if content.len == 0:
          return 0
        return commas + 1
    elif depth == 1 and info.tokens.tokenTextEquals(info.tokens[index], ","):
      inc commas
  -1

proc qualifiedMember*(
    info: SourceImports, diagnostic: CompilerDiagnostic
): tuple[qualifier, member: string] =
  let tokenIndex = findUsageToken(info, diagnostic)
  if tokenIndex >= 0 and tokenIndex + 2 < info.tokens.len and
      info.tokens.tokenTextEquals(info.tokens[tokenIndex + 1], ".") and
      info.tokens[tokenIndex + 2].kind == tkIdentifier:
    return (
      info.tokens.tokenText(info.tokens[tokenIndex]),
      info.tokens.tokenText(info.tokens[tokenIndex + 2]),
    )
  ("", "")
