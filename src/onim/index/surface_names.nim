import ../syntax/tokens

proc surfaceKey*(name: string): string {.inline.} =
  identifierKey(name)

proc validSurfaceName*(name: string): bool {.inline.} =
  surfaceKey(name).len > 0
