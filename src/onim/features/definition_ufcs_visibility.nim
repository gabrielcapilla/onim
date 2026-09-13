import ../index/type_states
import ../session/ids
import ../session/workspace
import ../session/workspace_models
import ../syntax/imports
import ../syntax/tokens
import ./definition_source_queries
import ./definition_visibility

proc importedUfcsName*(
    workspace: Workspace, source: WorkspaceSnapshot, provider: FileId, name: string
): tuple[state: TypeState, visible: bool] =
  result.state = typeStateResolved
  if workspace == nil or not validSource(source) or source.index == nil:
    result.state = typeStateUnknown
    return
  var uncertain = false
  for item in source.index.parsed.imports:
    if item.synthetic:
      continue
    let imported = workspace.resolveModule(source.fileId, item.module)
    if not imported.valid or imported.value != provider.value:
      continue
    case item.form
    of importModule:
      if item.conditional:
        uncertain = true
      elif item.alias.len == 0 and not item.excludedImport(name):
        result.visible = true
    of fromModule:
      if item.conditional or hasExcept(source.index.parsed, item):
        uncertain = true
        continue
      for symbol in item.importedSymbols:
        if not sameIdentifier(symbol.name, name):
          continue
        if plainImported(source.text, symbol):
          result.visible = true
        else:
          uncertain = true
  if not result.visible and uncertain:
    result.state = typeStateUnresolved
