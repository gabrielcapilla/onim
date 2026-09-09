import std/[os, sets, strutils]

import ../semantic/compiler_api
import ../stdlib/map
import ../syntax/imports
import ../syntax/import_queries
import ../syntax/module_names
import ../syntax/source_lines
import ../syntax/tokens

proc diagnosticBelongsToSource(
    diagnostic: CompilerDiagnostic, filePath, materializedPath: string
): bool =
  if diagnostic.file.len == 0:
    return true
  let reported = diagnostic.file.strip(chars = {'"', '\'', '`'})
  if reported.len == 0:
    return true
  let reportedPath = absolutePath(reported)
  if reportedPath == absolutePath(filePath) or
      reportedPath == absolutePath(materializedPath):
    return true
  if not reported.contains('/') and not reported.contains('\\'):
    return splitFile(reportedPath).name == splitFile(absolutePath(filePath)).name
  false

proc diagnosticMatchesImport(item: ImportInfo, diagnostic: CompilerDiagnostic): bool =
  let normalized = canonicalModule(item.module)
  let leaf = moduleLeaf(item.module)
  if diagnostic.name == item.alias or diagnostic.name == item.module or
      diagnostic.name == normalized or diagnostic.name == leaf:
    return true
  item.form == fromModule and diagnostic.name in item.imported

proc hasMissingExcludedSymbol*(
    item: ImportInfo,
    diagnostics: seq[CompilerDiagnostic],
    filePath, materializedPath: string,
): bool =
  if item.excluded.len == 0:
    return false
  for diagnostic in diagnostics:
    if not diagnostic.isUnusedImport and diagnostic.name in item.excluded and
        diagnosticBelongsToSource(diagnostic, filePath, materializedPath):
      return true

proc diagnosticRange(
    item: ImportInfo, diagnostic: CompilerDiagnostic
): tuple[startOffset, endOffset: int] =
  result = (item.diagnosticNameStartOffset, item.diagnosticNameEndOffset)
  if item.form == fromModule and diagnostic.name in item.imported:
    for symbol in item.importedSymbols:
      if symbol.name == diagnostic.name:
        return (symbol.startOffset, symbol.endOffset)

proc findUnusedImport*(
    source, filePath, materializedPath: string,
    imports: SourceImports,
    diagnostic: CompilerDiagnostic,
): int =
  var bestScore = -1
  var bestIndex = -1
  var ambiguous = false
  for index, item in imports.imports:
    if item.synthetic or item.conditional or item.keep or
        not diagnosticBelongsToSource(diagnostic, filePath, materializedPath) or
        not diagnosticMatchesImport(item, diagnostic):
      continue
    var score = 1
    if item.line == diagnostic.line:
      score += 100
      let location = lineStartOffset(source, diagnostic.line) + diagnostic.column
      let range = diagnosticRange(item, diagnostic)
      if diagnostic.column >= 0 and location >= range.startOffset and
          location < range.endOffset:
        score += 100
    if score > bestScore:
      bestScore = score
      bestIndex = index
      ambiguous = false
    elif score == bestScore:
      ambiguous = true
  if ambiguous: -1 else: bestIndex

proc hasIncludedSource*(imports: SourceImports): bool =
  for token in imports.tokens:
    if token.isKeyword(kwInclude):
      return true

proc importedNameUsed*(
    source: string, imports: SourceImports, item: ImportInfo, name: string
): bool =
  for tokenIndex, token in imports.tokens:
    if token.kind != tkIdentifier or not imports.tokens.tokenTextEquals(token, name) or
        token.startOffset <= item.endOffset or imports.tokenInsideImport(token):
      continue
    if tokenIndex > 0 and
        imports.tokens.tokenTextEquals(imports.tokens[tokenIndex - 1], "."):
      continue
    if name in imports.localDefinitions:
      return true
    return true
