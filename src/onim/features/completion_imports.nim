import std/sets

import ../index/source_index
import ../session/workspace
import ../session/workspace_models
import ../syntax/imports
import ../syntax/module_names
import ../syntax/tokens

type
  ImportMatchState* = enum
    importMatchMissing
    importMatchUnique
    importMatchAmbiguous

  ImportMatch* = object
    state*: ImportMatchState
    item*: ImportInfo

  ImportedSelectionKind* = enum
    importedSelectionSkip
    importedSelectionAll
    importedSelectionNamed

  ImportedName* = object
    localName*: string
    providerName*: string

  ImportedSelection* = object
    kind*: ImportedSelectionKind
    names*: seq[ImportedName]

proc importedQualifier*(item: ImportInfo): string {.inline.} =
  if item.alias.len > 0:
    item.alias
  else:
    moduleLeaf(item.module)

proc moduleDeclarationShadows*(index: SourceIndex, tokenIndex: int): bool =
  if index == nil or tokenIndex < 0 or tokenIndex >= index.parsed.tokens.len:
    return true
  let wanted = identifierKey(index.parsed.tokens, index.parsed.tokens[tokenIndex])
  if wanted.len == 0:
    return true
  for symbol in index.symbols:
    if symbol.nameToken == uint32(tokenIndex) or
        symbol.nameToken >= uint32(index.parsed.tokens.len):
      continue
    if identifierKey(index.parsed.tokens, index.parsed.tokens[int(symbol.nameToken)]) ==
        wanted:
      return true
  false

proc importForQualifier*(source: WorkspaceSnapshot, qualifier: string): ImportMatch =
  if source.index == nil or qualifier.len == 0:
    return
  for item in source.index.parsed.imports:
    if item.form != importModule or not sameIdentifier(
      item.importedQualifier, qualifier
    ):
      continue
    case result.state
    of importMatchMissing:
      result.state = importMatchUnique
      result.item = item
    of importMatchUnique, importMatchAmbiguous:
      result.state = importMatchAmbiguous
      return

proc importedSelection*(
    source: WorkspaceSnapshot, item: ImportInfo
): ImportedSelection =
  if source.index == nil or item.synthetic or
      source.index.parsed.conditionalImportDisposition(item) notin
      {importUnconditional, importConditionalActive}:
    return
  case item.form
  of importModule:
    if item.alias.len == 0:
      result.kind = importedSelectionAll
  of fromModule:
    result.kind = importedSelectionNamed
    for imported in item.importedSymbols:
      let binding =
        fromImportBinding(source.index.parsed.tokens, source.text, item, imported.name)
      if binding.kind in {fromImportPlain, fromImportAlias}:
        result.names.add ImportedName(
          localName: imported.name, providerName: binding.providerName
        )
    if result.names.len == 0:
      result.kind = importedSelectionSkip

proc excludedImportName*(item: ImportInfo, name: string): bool {.inline.} =
  for excluded in item.excluded:
    if sameIdentifier(excluded, name):
      return true

proc selectedImportedName*(
    selection: ImportedSelection, providerName: string
): string {.inline.} =
  case selection.kind
  of importedSelectionAll:
    result = providerName
  of importedSelectionNamed:
    for imported in selection.names:
      if sameIdentifier(imported.providerName, providerName):
        result = imported.localName
  of importedSelectionSkip:
    discard
