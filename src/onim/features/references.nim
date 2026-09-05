import ./definition
import ../index/occurrences
import ../index/scopes
import ../index/symbols
import ../session/ids
import ../session/workspace
import ../syntax/lexer

type SameFileReferences* = object
  supported*: bool
  tokens*: seq[uint32]

proc sameScope(source: WorkspaceSnapshot, left, right: uint32): bool {.inline.} =
  source.index.scopes.innermostScopeAt(left) ==
    source.index.scopes.innermostScopeAt(right)

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

  let targetScope = source.index.scopes.innermostScopeAt(selected.target.nameToken)
  if targetScope == InvalidScopeId or
      localTargetHasCompetingDeclaration(source, selected.target):
    return
  result.supported = true
  if includeDeclaration:
    result.tokens.add selected.target.nameToken

  let wanted = source.index.parsed.tokens[tokenIndex].text
  for occurrence in source.index.occurrences.identifiers:
    let occurrenceIndex = int(occurrence.token)
    if occurrenceIndex == int(selected.target.nameToken) or
        not sameIdentifier(source.index.parsed.tokens[occurrenceIndex].text, wanted) or
        not sameScope(source, selected.target.nameToken, occurrence.token) or
        occurrenceMember in occurrence.roles:
      continue
    if occurrenceIndex < int(selected.target.nameToken):
      result = SameFileReferences()
      return
    result.tokens.add occurrence.token
