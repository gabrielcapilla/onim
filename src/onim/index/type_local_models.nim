import ./type_ids
import ./type_kinds
import ./type_states

type
  LocalTypeForm* = enum
    localTypeFormUnknown
    localTypeFormAnnotation
    localTypeFormCall
    localTypeFormLiteral

  LocalTypeInfo* = object
    kind*: TypeKind
    state*: TypeState
    form*: LocalTypeForm
    typeId*: TypeId
    typeToken*: uint32
    firstToken*: uint32
    pastToken*: uint32
