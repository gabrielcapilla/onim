import ../semantic/worker
import ../session/ids
import ./semantic_key

proc removePending*(pending: var SemanticKey, key: SemanticKey) =
  if pending.fileId.valid and sameSemanticKey(pending, key):
    pending = SemanticKey()

proc removeQueued*(queued: var seq[SemanticRequest], fileId: FileId) =
  var writeIndex = 0
  for request in queued:
    if request.fileId.value != fileId.value:
      queued[writeIndex] = request
      inc writeIndex
  queued.setLen(writeIndex)

proc removeQueued*(
    queued: var seq[SemanticRequest], fileId: FileId, workKind: SemanticWorkKind
) =
  var writeIndex = 0
  for request in queued:
    if request.fileId.value != fileId.value or request.kind != workKind:
      queued[writeIndex] = request
      inc writeIndex
  queued.setLen(writeIndex)

proc removeQueued*(queued: var seq[SemanticRequest], key: SemanticKey) =
  var writeIndex = 0
  for request in queued:
    if not sameSemanticKey(semanticKey(request), key):
      queued[writeIndex] = request
      inc writeIndex
  queued.setLen(writeIndex)

proc queueSemantic*(queued: var seq[SemanticRequest], request: SemanticRequest) =
  removeQueued(queued, request.fileId, request.kind)
  queued.add request
