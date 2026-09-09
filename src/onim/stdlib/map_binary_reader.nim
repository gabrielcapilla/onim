type BinaryReader* = object
  data*: string
  position*: int
  valid*: bool

proc readByte*(reader: var BinaryReader): uint8 =
  if not reader.valid or reader.position < 0 or reader.position >= reader.data.len:
    reader.valid = false
    return
  result = uint8(ord(reader.data[reader.position]))
  inc reader.position

proc readUint32*(reader: var BinaryReader): uint32 =
  for shift in 0 .. 3:
    result = result or (uint32(reader.readByte()) shl (shift * 8))

proc readInt32*(reader: var BinaryReader): int32 =
  cast[int32](reader.readUint32())

proc readUint64*(reader: var BinaryReader): uint64 =
  for shift in 0 .. 7:
    result = result or (uint64(reader.readByte()) shl (shift * 8))

proc ensureBytes*(reader: var BinaryReader, count: int): bool =
  if not reader.valid or count < 0 or count > reader.data.len - reader.position:
    reader.valid = false
    return false
  true

proc ensureRecords*(reader: var BinaryReader, count, width: int): bool =
  if count < 0 or width < 0 or
      uint64(count) * uint64(width) > uint64(max(reader.data.len - reader.position, 0)):
    reader.valid = false
    return false
  true

proc readCount*(reader: var BinaryReader, maximum: int): int =
  let count = reader.readUint32()
  if not reader.valid or count > uint32(maximum):
    reader.valid = false
    return -1
  int(count)

proc readStringId*(reader: var BinaryReader, strings: openArray[string]): string =
  let id = reader.readUint32()
  if not reader.valid or id >= uint32(strings.len):
    reader.valid = false
    return
  strings[int(id)]
