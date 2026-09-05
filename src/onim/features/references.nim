import ./definition
import ../index/bindings
import ../index/occurrences
import ../index/symbols
import ../session/ids
import ../session/workspace
import ../syntax/lexer

type SameFileReferences* = object
  supported*: bool
  tokens*: seq[uint32]

proc resolveSameFileReferences*(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    byteOffset: int,
    includeDeclaration: bool,
): SameFileReferences =
  if workspace == nil or not source.valid or source.index == nil:
    return
  let tokenIndex = tokenAtOffset(source.index.parsed.tokens, byteOffset)
  if tokenIndex < 0:
    return
  let selected = resolveLocalDefinitionAtToken(source, tokenIndex)
  if selected.kind != definitionResolved or
      selected.target.fileId.value != source.fileId.value:
    return

  if tokenIndex != int(selected.target.nameToken):
    let roles = source.index.occurrences.rolesForToken(uint32(tokenIndex))
    if occurrenceReference notin roles or occurrenceMember in roles:
      return

  result.supported = true
  if includeDeclaration:
    result.tokens.add selected.target.nameToken

  let wanted =
    identifierKey(source.index.parsed.tokens[int(selected.target.nameToken)].text)
  for occurrence in source.index.occurrences.identifiers:
    let occurrenceIndex = int(occurrence.token)
    if occurrenceIndex == int(selected.target.nameToken) or
        identifierKey(source.index.parsed.tokens[occurrenceIndex].text) != wanted or
        occurrenceMember in occurrence.roles:
      continue
    let binding = source.index.resolveBinding(occurrence.token)
    if binding.state == bindingResolved and
        binding.declarationToken == selected.target.nameToken:
      result.tokens.add occurrence.token
    elif binding.state != bindingResolved and
        source.index.bindingRegionContains(selected.target.nameToken, occurrence.token):
      result = SameFileReferences()
      return
