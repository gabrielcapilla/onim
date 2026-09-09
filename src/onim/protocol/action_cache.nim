import ../features/organize
import ../features/organize_edits
import ../session/ids

type CachedAction* = object
  contentGeneration*: ContentGeneration
  dependencyGeneration*: DependencyGeneration
  configGeneration*: ConfigGeneration
  surfaceGeneration*: SurfaceGeneration
  useStdPrefix*: bool
  edits*: seq[ImportEdit]

proc hasCachedAction*(cache: seq[CachedAction], id: FileId): bool {.inline.} =
  let slot = id.slot
  slot >= 0 and slot < cache.len and
    cache[slot].contentGeneration.value != InvalidContentGeneration.value

proc cachedActionFor*(cache: seq[CachedAction], id: FileId): CachedAction {.inline.} =
  let slot = id.slot
  if slot >= 0 and slot < cache.len:
    result = cache[slot]

proc storeCachedAction*(
    cache: var seq[CachedAction], id: FileId, action: CachedAction
) {.inline.} =
  let slot = id.slot
  if slot < 0:
    return
  if slot >= cache.len:
    cache.setLen(slot + 1)
  cache[slot] = action

proc clearCachedAction*(cache: var seq[CachedAction], id: FileId) {.inline.} =
  let slot = id.slot
  if slot < 0 or slot >= cache.len:
    return
  cache[slot] = CachedAction()
  while cache.len > 0 and
      cache[^1].contentGeneration.value == InvalidContentGeneration.value:
    cache.setLen(cache.len - 1)
