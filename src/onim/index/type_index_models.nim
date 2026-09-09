import ./type_ids
import ./type_kinds

type
  ObjectFieldVisibility* = enum
    objectFieldPrivate
    objectFieldExported

  ObjectTypeRecord* = object
    declarationToken*: uint32
    firstField*: uint32
    pastField*: uint32
    firstGenericParameter*: uint32
    pastGenericParameter*: uint32

  ObjectField* = object
    nameToken*: uint32
    visibility*: ObjectFieldVisibility

  TypeRecord* = object
    kind*: TypeKind
    nameToken*: uint32
    baseType*: TypeId
    extent*: uint32
    firstArgument*: uint32
    pastArgument*: uint32

  UfcsProcedureRecord* = object
    typeId*: TypeId
    symbolOrdinal*: uint32
    parameterOrdinal*: uint32

  TypeIndex* = object
    records*: seq[TypeRecord]
    genericArgumentTypeIds*: seq[TypeId]
    objects*: seq[ObjectTypeRecord]
    fields*: seq[ObjectField]
    localTupleObjects*: seq[ObjectTypeRecord]
    localTupleFields*: seq[ObjectField]
    genericParameterTokens*: seq[uint32]
    localTypeIds*: seq[TypeId]
    routineReturnTypeIds*: seq[TypeId]
    ufcsProcedures*: seq[UfcsProcedureRecord]
