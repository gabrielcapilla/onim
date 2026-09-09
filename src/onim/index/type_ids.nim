type TypeId* = distinct uint32

const InvalidTypeId* = TypeId(0'u32)

proc valid*(id: TypeId): bool {.inline.} =
  uint32(id) != 0'u32

proc `==`*(left, right: TypeId): bool {.inline.} =
  uint32(left) == uint32(right)
