import std/strutils

import ./import_lines
import ./imports
import ./module_names
import ./statement_ranges
import ./tokens

proc includeSegment(tokens: TokenStore, index: int): bool {.inline.} =
  if index < 0 or index >= tokens.len:
    return false
  let token = tokens[index]
  (token.kind == tkIdentifier and token.validIdentifier) or
    (token.kind == tkString and token.isClosedString)

proc includeSeparator(tokens: TokenStore, index: int): bool {.inline.} =
  index >= 0 and index < tokens.len and (
    tokens.tokenTextEquals(tokens[index], "/") or
    tokens.tokenTextEquals(tokens[index], ".") or
    tokens.tokenTextEquals(tokens[index], "\\")
  )

proc parseIncludePath(
    tokens: TokenStore, cursor: var int, finish: int
): tuple[path: string, firstToken, pastToken: int, valid: bool] =
  result.firstToken = cursor
  if not includeSegment(tokens, cursor):
    return
  result.path = tokens.tokenText(tokens[cursor])
  inc cursor
  while cursor < finish and includeSeparator(tokens, cursor):
    result.path.add tokens.tokenText(tokens[cursor])
    inc cursor
    if not includeSegment(tokens, cursor):
      return
    result.path.add tokens.tokenText(tokens[cursor])
    inc cursor
  result.pastToken = cursor
  result.valid = true

proc includeInfo(
    tokens: TokenStore,
    source: string,
    lines: openArray[string],
    statementStart, statementPast, firstToken, pastToken: int,
    module: string,
): ImportInfo =
  if statementStart < 0 or statementPast <= statementStart or statementPast > tokens.len or
      firstToken < 0 or pastToken <= firstToken or pastToken > tokens.len:
    return
  result.form = importModule
  result.module = canonicalReference(module)
  result.startOffset = tokens[statementStart].startOffset
  result.endOffset = tokens[statementPast - 1].endOffset
  result.moduleStartOffset = tokens[firstToken].startOffset
  result.moduleEndOffset = tokens[pastToken - 1].endOffset
  result.diagnosticNameStartOffset = result.moduleStartOffset
  result.diagnosticNameEndOffset = result.moduleEndOffset
  result.itemStartOffset = result.moduleStartOffset
  result.itemEndOffset = result.moduleEndOffset
  result.line = tokens[statementStart].line
  result.indent = lineIndent(source, tokens[statementStart].startOffset)
  if lines.len > 0:
    result.conditional = conditionalImport(lines, tokens[statementStart])

proc parseIncludeItem(
    tokens: TokenStore,
    source: string,
    lines: openArray[string],
    statementStart, statementPast: int,
    cursor: var int,
    finish: int,
): tuple[references: seq[ImportInfo], valid: bool] =
  if not includeSegment(tokens, cursor):
    return
  let firstToken = cursor
  var prefix = tokens.tokenText(tokens[cursor])
  inc cursor
  while cursor < finish and includeSeparator(tokens, cursor):
    let separator = tokens.tokenText(tokens[cursor])
    inc cursor
    if cursor < finish and tokens.tokenTextEquals(tokens[cursor], "[") and
        separator == "/":
      prefix.add separator
      inc cursor
      var groupCount = 0
      while cursor < finish:
        if not includeSegment(tokens, cursor):
          result.valid = false
          return
        let suffix = parseIncludePath(tokens, cursor, finish)
        if not suffix.valid:
          return
        result.references.add includeInfo(
          tokens,
          source,
          lines,
          statementStart,
          statementPast,
          suffix.firstToken,
          suffix.pastToken,
          prefix & suffix.path,
        )
        inc groupCount
        if cursor >= finish:
          return
        if tokens.tokenTextEquals(tokens[cursor], ","):
          inc cursor
          if cursor >= finish or tokens.tokenTextEquals(tokens[cursor], "]"):
            return
        elif tokens.tokenTextEquals(tokens[cursor], "]"):
          inc cursor
          result.valid = groupCount > 0
          return
        else:
          return
      return
    if not includeSegment(tokens, cursor):
      return
    prefix.add separator
    prefix.add tokens.tokenText(tokens[cursor])
    inc cursor
  result.references.add includeInfo(
    tokens, source, lines, statementStart, statementPast, firstToken, cursor, prefix
  )
  result.valid = true

proc parseIncludeReferences*(
    tokens: TokenStore, source: string, index: int
): tuple[references: seq[ImportInfo], next: int, uncertainty: set[StatementUncertainty]] =
  let statement = statementRange(tokens, index)
  let endIndex = statement.past
  let lines = source.splitLines
  result.next = endIndex
  result.uncertainty = statement.uncertainty
  if statementHasMissingOperand(tokens, index, endIndex):
    result.uncertainty.incl statementIncomplete
    return
  var cursor = index + 1
  while cursor < endIndex:
    let item =
      parseIncludeItem(tokens, source, lines, index, endIndex, cursor, endIndex)
    if not item.valid:
      result.references.setLen(0)
      result.uncertainty.incl statementUnsupported
      return
    for reference in item.references:
      if reference.module.len == 0:
        result.references.setLen(0)
        result.uncertainty.incl statementUnsupported
        return
      result.references.add reference
    if cursor >= endIndex:
      break
    if not tokens.tokenTextEquals(tokens[cursor], ","):
      result.references.setLen(0)
      result.uncertainty.incl statementUnsupported
      return
    inc cursor
    if cursor >= endIndex:
      result.references.setLen(0)
      result.uncertainty.incl statementIncomplete
      return
  if result.references.len == 0:
    result.uncertainty.incl statementIncomplete
