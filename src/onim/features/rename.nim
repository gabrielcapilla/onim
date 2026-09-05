import ./references
import ../session/workspace
import ../syntax/lexer

type
  RenameState* = enum
    renameUnavailable
    renameAvailable

  RenameInfo* = object
    state*: RenameState
    tokens*: seq[uint32]

proc validRenameName(name: string): bool =
  let token = Token(kind: tkIdentifier, text: name, startOffset: 0, endOffset: name.len)
  validIdentifier(token) and not isNimKeyword(token) and not isStropped(token)

proc renameLocal*(
    workspace: Workspace, source: WorkspaceSnapshot, byteOffset: int, newName: string
): RenameInfo =
  if not validRenameName(newName):
    return
  let references = resolveSameFileReferences(workspace, source, byteOffset, true)
  if not references.supported:
    return
  result.state = renameAvailable
  result.tokens = references.tokens
