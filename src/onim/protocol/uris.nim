import std/[strutils, uri]

proc uriToPath*(uriText: string): string =
  if uriText.startsWith("file://"):
    result = decodeUrl(uriText[7 .. ^1])
    when defined(windows):
      if result.len > 0 and result[0] == '/' and result.len > 2 and result[2] == ':':
        result = result[1 .. ^1]
      result = result.replace('/', '\\')
    else:
      if not result.startsWith("/"):
        result = "/" & result
  else:
    result = uriText

proc uriPathByte(character: char): bool =
  (character >= 'a' and character <= 'z') or (character >= 'A' and character <= 'Z') or
    (character >= '0' and character <= '9') or
    character in {'-', '.', '_', '~', '/', ':'}

proc hexDigit(value: int): char =
  if value < 10:
    char(ord('0') + value)
  else:
    char(ord('A') + value - 10)

proc fileUri*(path: string): string =
  result = "file://"
  for character in path:
    let normalized =
      when defined(windows):
        if character == '\\': '/' else: character
      else:
        character
    if normalized.uriPathByte:
      result.add normalized
    else:
      let value = ord(normalized)
      result.add '%'
      result.add hexDigit((value shr 4) and 0x0F)
      result.add hexDigit(value and 0x0F)
