import std/[algorithm, sets, streams]

const
  maxStringBytes* = 4 * 1024 * 1024
  maxRecordCount* = 1_000_000

proc invalidCache*(message: string) {.noreturn.} =
  raise newException(IOError, message)

proc writeCount*(stream: Stream, count, maximum: int) =
  if count < 0 or count > maximum:
    invalidCache("cache count is out of bounds")
  stream.write(uint32(count))

proc readCount*(stream: Stream, maximum: int): int =
  let count = stream.readUint32()
  if count > uint32(maximum):
    invalidCache("cache count is out of bounds")
  int(count)

proc writeString*(stream: Stream, value: string) =
  if value.len > maxStringBytes:
    invalidCache("cache string is out of bounds")
  stream.write(uint32(value.len))
  if value.len > 0:
    stream.write(value)

proc readString*(stream: Stream): string =
  let length = stream.readUint32()
  if length > uint32(maxStringBytes):
    invalidCache("cache string is out of bounds")
  if length > 0:
    result = stream.readStr(int(length))

proc writeInt*(stream: Stream, value: int) =
  stream.write(int64(value))

proc readInt*(stream: Stream): int =
  let value = stream.readInt64()
  if value < int64(low(int)) or value > int64(high(int)):
    invalidCache("cache integer is out of bounds")
  int(value)

proc writeFlag*(stream: Stream, value: bool) =
  stream.write(if value: 1'u8 else: 0'u8)

proc readFlag*(stream: Stream): bool =
  let value = stream.readUint8()
  if value > 1'u8:
    invalidCache("cache flag is invalid")
  value == 1'u8

proc sortedValues*(values: HashSet[string]): seq[string] =
  result = newSeqOfCap[string](values.len)
  for value in values:
    result.add value
  result.sort

proc writeStrings*(stream: Stream, values: seq[string]) =
  writeCount(stream, values.len, maxRecordCount)
  for value in values:
    writeString(stream, value)

proc readStrings*(stream: Stream): seq[string] =
  let count = readCount(stream, maxRecordCount)
  result = newSeqOfCap[string](count)
  for _ in 0 ..< count:
    result.add readString(stream)

proc writeStringSet*(stream: Stream, values: HashSet[string]) =
  writeStrings(stream, sortedValues(values))

proc readStringSet*(stream: Stream): HashSet[string] =
  result = initHashSet[string]()
  let values = readStrings(stream)
  for value in values:
    result.incl value
