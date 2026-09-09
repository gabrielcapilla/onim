import std/[sets, strutils]

import ./imports
import ./module_names
import ./tokens

proc tokenInsideImport*(imports: SourceImports, token: Token): bool =
  for item in imports.imports:
    if not item.synthetic and token.startOffset >= item.startOffset and
        token.endOffset <= item.endOffset:
      return true

proc hasModuleImport*(imports: SourceImports, module: string): bool =
  for item in imports.imports:
    if item.form == importModule and not item.conditional and item.alias.len == 0 and
        item.excluded.len == 0 and (
      item.module == module or item.module.endsWith('/' & module) or
      (module.startsWith("std/") and item.module == module[4 .. ^1])
    ):
      return true

proc providesName*(imports: SourceImports, name: string): bool =
  if name in imports.localDefinitions:
    return true
  name in imports.availableNames

proc providesQualifier*(imports: SourceImports, qualifier: string): bool =
  for known in imports.qualifiedNames:
    if sameIdentifier(known, qualifier):
      return true
  for item in imports.imports:
    if item.form == importModule and not item.conditional:
      let known =
        if item.alias.len > 0:
          item.alias
        else:
          moduleLeaf(item.module)
      if sameIdentifier(known, qualifier):
        return true
  false
