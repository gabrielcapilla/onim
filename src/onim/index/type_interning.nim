import ./type_ids
import ./type_annotation_syntax
import ./type_index_models
import ./type_kinds
import ./type_queries

proc validTypeShape(
    kind: TypeKind, nameToken: uint32, baseType: TypeId, extent = 0'u32
): bool {.inline.} =
  case kind
  of typeNamed:
    nameToken != InvalidTypeToken and not baseType.valid and extent == 0'u32
  of typeSeq, typeRef:
    nameToken == InvalidTypeToken and baseType.valid and extent == 0'u32
  of typeArray:
    nameToken == InvalidTypeToken and baseType.valid
  of typeGenericInstance:
    nameToken != InvalidTypeToken and baseType.valid and extent == 0'u32
  of typeUnknown:
    false
  else:
    nameToken == InvalidTypeToken and not baseType.valid and extent == 0'u32

proc sameGenericArguments(
    types: TypeIndex, record: TypeRecord, arguments: seq[TypeId]
): bool {.inline.} =
  if record.pastArgument < record.firstArgument or
      record.pastArgument > uint32(types.genericArgumentTypeIds.len) or
      int(record.pastArgument - record.firstArgument) != arguments.len:
    return false
  for index, argument in arguments:
    if types.genericArgumentTypeIds[int(record.firstArgument) + index] != argument:
      return false
  true

proc sameGenericRecordArguments*(
    types: TypeIndex, left, right: TypeRecord
): bool {.inline.} =
  if left.pastArgument < left.firstArgument or right.pastArgument < right.firstArgument or
      left.pastArgument > uint32(types.genericArgumentTypeIds.len) or
      right.pastArgument > uint32(types.genericArgumentTypeIds.len) or
      left.pastArgument - left.firstArgument != right.pastArgument - right.firstArgument:
    return false
  for index in 0 ..< int(left.pastArgument - left.firstArgument):
    if types.genericArgumentTypeIds[int(left.firstArgument) + index] !=
        types.genericArgumentTypeIds[int(right.firstArgument) + index]:
      return false
  true

proc typeIdFor*(
    types: TypeIndex,
    kind: TypeKind,
    nameToken = InvalidTypeToken,
    baseType = InvalidTypeId,
    extent = 0'u32,
    genericArguments: seq[TypeId] = @[],
): TypeId {.inline.} =
  if not validTypeShape(kind, nameToken, baseType, extent):
    return InvalidTypeId
  if kind == typeGenericInstance and
      (genericArguments.len == 0 or genericArguments[0] != baseType):
    return InvalidTypeId
  for ordinal, record in types.records:
    if record.kind == kind and record.nameToken == nameToken and
        record.baseType == baseType and record.extent == extent and
        types.sameGenericArguments(record, genericArguments):
      return TypeId(uint32(ordinal + 1))
  InvalidTypeId

proc internType*(
    types: var TypeIndex,
    kind: TypeKind,
    nameToken = InvalidTypeToken,
    baseType = InvalidTypeId,
    extent = 0'u32,
    genericArguments: seq[TypeId] = @[],
): TypeId =
  let existing = types.typeIdFor(kind, nameToken, baseType, extent, genericArguments)
  if existing.valid:
    return existing
  if not validTypeShape(kind, nameToken, baseType, extent):
    return InvalidTypeId
  if kind == typeGenericInstance and
      (genericArguments.len == 0 or genericArguments[0] != baseType):
    return InvalidTypeId
  let firstArgument = uint32(types.genericArgumentTypeIds.len)
  types.genericArgumentTypeIds.add genericArguments
  types.records.add TypeRecord(
    kind: kind,
    nameToken: nameToken,
    baseType: baseType,
    extent: extent,
    firstArgument: firstArgument,
    pastArgument: uint32(types.genericArgumentTypeIds.len),
  )
  TypeId(uint32(types.records.len))

proc genericArgumentTypeId*(
    types: TypeIndex, argument: GenericArgumentDescriptor
): TypeId {.inline.} =
  if argument.kind.isPrimitiveType:
    types.typeIdFor(argument.kind)
  elif argument.kind == typeNamed:
    types.typeIdFor(typeNamed, argument.nameToken)
  else:
    InvalidTypeId

proc internGenericArgumentTypeId*(
    types: var TypeIndex, argument: GenericArgumentDescriptor
): TypeId {.inline.} =
  if argument.kind.isPrimitiveType:
    types.internType(argument.kind)
  elif argument.kind == typeNamed:
    types.internType(typeNamed, argument.nameToken)
  else:
    InvalidTypeId

proc genericArgumentTypeIds*(
    types: TypeIndex, descriptor: TypeDescriptor
): seq[TypeId] =
  for argument in descriptor.genericArguments:
    let typeId = types.genericArgumentTypeId(argument)
    if not typeId.valid:
      return @[]
    result.add typeId

proc internGenericArgumentTypeIds*(
    types: var TypeIndex, descriptor: TypeDescriptor
): seq[TypeId] =
  for argument in descriptor.genericArguments:
    let typeId = types.internGenericArgumentTypeId(argument)
    if not typeId.valid:
      return @[]
    result.add typeId

proc descriptorTypeId*(types: TypeIndex, descriptor: TypeDescriptor): TypeId =
  let genericArguments = types.genericArgumentTypeIds(descriptor)
  let baseType =
    case descriptor.kind
    of typeSeq:
      if descriptor.baseKind == typeNamed:
        types.typeIdFor(typeNamed, descriptor.baseNameToken)
      else:
        types.typeIdFor(descriptor.baseKind)
    of typeRef:
      types.typeIdFor(typeNamed, descriptor.baseNameToken)
    of typeArray:
      if descriptor.baseKind == typeNamed:
        types.typeIdFor(typeNamed, descriptor.baseNameToken)
      else:
        types.typeIdFor(descriptor.baseKind)
    of typeGenericInstance:
      if genericArguments.len > 0:
        genericArguments[0]
      else:
        InvalidTypeId
    else:
      InvalidTypeId
  types.typeIdFor(
    descriptor.kind, descriptor.nameToken, baseType, descriptor.extent, genericArguments
  )

proc internDescriptor*(types: var TypeIndex, descriptor: TypeDescriptor): TypeId =
  let genericArguments = types.internGenericArgumentTypeIds(descriptor)
  let baseType =
    case descriptor.kind
    of typeSeq:
      if descriptor.baseKind == typeNamed:
        types.internType(typeNamed, descriptor.baseNameToken)
      else:
        types.internType(descriptor.baseKind)
    of typeRef:
      types.internType(typeNamed, descriptor.baseNameToken)
    of typeArray:
      if descriptor.baseKind == typeNamed:
        types.internType(typeNamed, descriptor.baseNameToken)
      else:
        types.internType(descriptor.baseKind)
    of typeGenericInstance:
      if genericArguments.len > 0:
        genericArguments[0]
      else:
        InvalidTypeId
    else:
      InvalidTypeId
  types.internType(
    descriptor.kind, descriptor.nameToken, baseType, descriptor.extent, genericArguments
  )
