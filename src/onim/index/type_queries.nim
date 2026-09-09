import ./type_ids
import ./type_index_models
import ./type_kinds
import ./type_local_models
import ./type_states

const InvalidTypeToken* = high(uint32)

proc typeKind*(types: TypeIndex, id: TypeId): TypeKind {.inline.} =
  let ordinal = int(uint32(id)) - 1
  if ordinal >= 0 and ordinal < types.records.len:
    types.records[ordinal].kind
  else:
    typeUnknown

proc typeBase*(types: TypeIndex, id: TypeId): TypeId {.inline.} =
  let ordinal = int(uint32(id)) - 1
  if ordinal >= 0 and ordinal < types.records.len:
    types.records[ordinal].baseType
  else:
    InvalidTypeId

proc typeNameToken*(types: TypeIndex, id: TypeId): uint32 {.inline.} =
  let ordinal = int(uint32(id)) - 1
  if ordinal >= 0 and ordinal < types.records.len and
      types.records[ordinal].kind == typeNamed:
    types.records[ordinal].nameToken
  else:
    InvalidTypeToken

proc genericArgumentCount*(types: TypeIndex, id: TypeId): int {.inline.} =
  let ordinal = int(uint32(id)) - 1
  if ordinal < 0 or ordinal >= types.records.len or
      types.records[ordinal].kind != typeGenericInstance:
    return 0
  let record = types.records[ordinal]
  if record.pastArgument < record.firstArgument or
      record.pastArgument > uint32(types.genericArgumentTypeIds.len):
    return 0
  int(record.pastArgument - record.firstArgument)

proc genericArgumentType*(types: TypeIndex, id: TypeId, index: int): TypeId {.inline.} =
  let ordinal = int(uint32(id)) - 1
  if ordinal < 0 or ordinal >= types.records.len or
      types.records[ordinal].kind != typeGenericInstance:
    return InvalidTypeId
  let record = types.records[ordinal]
  let argument = int(record.firstArgument) + index
  if index < 0 or argument < int(record.firstArgument) or
      argument >= int(record.pastArgument) or
      argument >= types.genericArgumentTypeIds.len:
    return InvalidTypeId
  types.genericArgumentTypeIds[argument]

proc namedTypeId*(types: TypeIndex, id: TypeId): TypeId {.inline.} =
  case types.typeKind(id)
  of typeNamed:
    id
  of typeRef:
    let base = types.typeBase(id)
    if types.typeKind(base) == typeNamed: base else: InvalidTypeId
  else:
    InvalidTypeId

proc supportedGenericInstance*(types: TypeIndex, info: LocalTypeInfo): bool =
  if info.kind != typeGenericInstance or info.state != typeStateResolved or
      info.form != localTypeFormAnnotation or info.typeToken == InvalidTypeToken:
    return false
  if types.typeKind(info.typeId) != typeGenericInstance:
    return false
  let count = types.genericArgumentCount(info.typeId)
  if count == 0:
    return false
  for index in 0 ..< count:
    let argument = types.genericArgumentType(info.typeId, index)
    let kind = types.typeKind(argument)
    if not kind.isPrimitiveType and kind != typeNamed:
      return false
    if kind == typeNamed and types.typeNameToken(argument) == InvalidTypeToken:
      return false
  true
