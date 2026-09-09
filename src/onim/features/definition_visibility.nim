import std/[sets, strutils]

import ../index/bindings
import ../index/scopes
import ../index/scope_queries
import ../index/source_index
import ../session/workspace
import ../session/workspace_models
import ../syntax/imports
import ../syntax/module_names
import ../syntax/tokens

proc localDeclarationShadows*(
    source: WorkspaceSnapshot, tokenIndex: int, name: string
): bool =
  if source.index == nil or not source.index.bindingsReady or tokenIndex < 0 or
      tokenIndex >= source.index.parsed.tokens.len:
    return true
  let wanted = identifierKey(name)
  if wanted.len == 0:
    return true
  var scope = source.index.scopes.innermostScopeAt(uint32(tokenIndex))
  while source.index.scopes.isLocalScope(scope):
    for declaration in source.index.scopes.declarations:
      if declaration.scope != scope or declaration.nameToken == uint32(tokenIndex) or
          declaration.nameToken >= uint32(source.index.parsed.tokens.len):
        continue
      if identifierKey(
        source.index.parsed.tokens,
        source.index.parsed.tokens[int(declaration.nameToken)],
      ) == wanted:
        return true
    scope = source.index.scopes.parentScope(scope)
  false

proc importedUseSupported*(
    source: WorkspaceSnapshot, tokenIndex: int, name: string
): bool =
  if source.index == nil or not source.index.bindingsReady or tokenIndex < 0 or
      tokenIndex >= source.index.parsed.tokens.len:
    return false
  let binding = source.index.resolveBinding(uint32(tokenIndex))
  if binding.state != bindingUnknown:
    return false
  if source.index.implicitNameKind(uint32(tokenIndex)) != implicitNone:
    return false
  not source.localDeclarationShadows(tokenIndex, name)

proc hasExcept*(imports: SourceImports, item: ImportInfo): bool =
  for token in imports.tokens:
    if token.startOffset < item.startOffset or token.endOffset > item.endOffset:
      continue
    if token.isKeyword(kwExcept):
      return true
  false

proc plainImported*(source: string, symbol: ImportSymbol): bool =
  if symbol.startOffset < 0 or symbol.endOffset < symbol.startOffset or
      symbol.endOffset > source.len:
    return false
  source[symbol.startOffset ..< symbol.endOffset].strip(chars = {'`'}) == symbol.name

proc excludedImport*(item: ImportInfo, name: string): bool =
  for excluded in item.excluded:
    if sameIdentifier(excluded, name):
      return true
  false

proc fromBindingState*(
    source: WorkspaceSnapshot, name: string
): tuple[found, uncertain: bool] =
  for item in source.index.parsed.imports:
    if item.form != fromModule:
      continue
    for symbol in item.importedSymbols:
      if not sameIdentifier(symbol.name, name):
        continue
      result.found = true
      let binding =
        fromImportBinding(source.index.parsed.tokens, source.text, item, name)
      if binding.kind == fromImportUnsupported:
        result.uncertain = true

proc qualifierMatches*(item: ImportInfo, qualifier: string): bool =
  if item.alias.len > 0:
    sameIdentifier(item.alias, qualifier)
  else:
    sameIdentifier(moduleLeaf(item.module), qualifier)
