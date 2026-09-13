import ../index/source_index
import ../index/type_index_models
import ../index/type_field_queries
import ../session/workspace_models
import ../syntax/tokens
import ./definition_models
import ./definition_resolution_results

proc resolveObjectField*(
    source: WorkspaceSnapshot, receiver: ObjectReceiverResolution, memberToken: int
): DefinitionResolution =
  if not receiver.resolved or receiver.provider == nil or memberToken < 0 or
      memberToken >= source.index.parsed.tokens.len:
    return unknownResolution(definitionUnsupported)
  let provider = receiver.provider
  let objectOrdinal = int(receiver.objectOrdinal)
  var objectType: ObjectTypeRecord
  var fields: seq[ObjectField]
  case receiver.fieldSource
  of objectFieldsNominal:
    if objectOrdinal < 0 or objectOrdinal >= provider.types.objects.len:
      return unknownResolution(definitionUnsupported)
    objectType = provider.types.objects[objectOrdinal]
    fields = provider.types.fields
  of objectFieldsLocalTuple:
    if objectOrdinal < 0 or objectOrdinal >= provider.types.localTupleObjects.len:
      return unknownResolution(definitionUnsupported)
    objectType = provider.types.localTupleObjects[objectOrdinal]
    fields = provider.types.localTupleFields
  if objectType.firstField > objectType.pastField or
      objectType.pastField > uint32(fields.len):
    return unknownResolution(definitionUnsupported)
  var matched = -1
  let wanted =
    source.index.parsed.tokens.tokenText(source.index.parsed.tokens[memberToken])
  for fieldIndex in objectType.firstField ..< objectType.pastField:
    let field = fields[int(fieldIndex)]
    if receiver.exportedOnly and field.visibility != objectFieldExported:
      continue
    if field.nameToken >= uint32(provider.parsed.tokens.len):
      return unknownResolution(definitionUnsupported)
    if not sameIdentifier(
      provider.parsed.tokens.tokenText(provider.parsed.tokens[int(field.nameToken)]),
      wanted,
    ):
      continue
    if matched >= 0:
      return unknownResolution(definitionAmbiguous)
    matched = int(fieldIndex)
  if matched < 0:
    return unknownResolution(definitionUnsupported)
  let field = fields[matched]
  result.kind = definitionResolved
  result.target = DefinitionTarget(
    kind: targetObjectField,
    snapshotId: source.id,
    fileId: receiver.typeTarget.fileId,
    contentGeneration: receiver.typeTarget.contentGeneration,
    nameToken: field.nameToken,
  )

proc resolveObjectFieldDeclaration*(
    source: WorkspaceSnapshot, tokenIndex: int
): DefinitionResolution =
  if not source.index.nativeIndexSafe():
    return unknownResolution(definitionUnsupported)
  let fieldOrdinal = source.index.types.objectFieldOrdinal(uint32(tokenIndex))
  if fieldOrdinal < 0:
    return unknownResolution()
  for objectType in source.index.types.objects:
    if uint32(fieldOrdinal) < objectType.firstField or
        uint32(fieldOrdinal) >= objectType.pastField:
      continue
    let field = source.index.types.fields[fieldOrdinal]
    result.kind = definitionResolved
    result.target = DefinitionTarget(
      kind: targetObjectField,
      snapshotId: source.id,
      fileId: source.fileId,
      contentGeneration: source.contentGeneration,
      nameToken: field.nameToken,
    )
    return
  unknownResolution(definitionUnsupported)
