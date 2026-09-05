import std/[algorithm, os, strutils]

import ./paths

type
  DiscoveryStatus* = enum
    discoveryComplete
    discoveryCancelled
    discoveryFailed

  DiscoveryCancellation* = proc(): bool {.gcsafe.}

  DiscoveryResult* = object
    status*: DiscoveryStatus
    paths*: seq[string]
    directoriesVisited*: uint32
    directoriesPruned*: uint32
    entriesExamined*: uint32
    errorPath*: string

const prunedDirectoryNames = [".git", ".cache", "nimcache"]

proc shouldCancel(cancellation: DiscoveryCancellation): bool {.inline.} =
  cancellation != nil and cancellation()

proc prunedDirectory(path: string): bool {.inline.} =
  let name = lastPathPart(path).toLowerAscii
  for candidate in prunedDirectoryNames:
    if name == candidate:
      return true
  false

proc nimSourcePath(path: string): bool {.inline.} =
  path.toLowerAscii.endsWith(".nim")

proc discoverSources*(
    root: string, cancellation: DiscoveryCancellation = nil
): DiscoveryResult {.gcsafe.} =
  result.status = discoveryFailed
  let canonicalRoot = canonicalPath(root)
  if canonicalRoot.len == 0 or not dirExists(canonicalRoot):
    result.errorPath = canonicalRoot
    return

  var pending = @[canonicalRoot]
  while pending.len > 0:
    if cancellation.shouldCancel:
      result.status = discoveryCancelled
      result.paths.setLen(0)
      return
    let directory = pending.pop()
    inc result.directoriesVisited
    try:
      for kind, path in walkDir(directory):
        if cancellation.shouldCancel:
          result.status = discoveryCancelled
          result.paths.setLen(0)
          return
        inc result.entriesExamined
        case kind
        of pcDir:
          if prunedDirectory(path):
            inc result.directoriesPruned
          else:
            pending.add canonicalPath(path)
        of pcFile:
          if nimSourcePath(path):
            result.paths.add canonicalPath(path)
        else:
          discard
    except CatchableError:
      result.errorPath = directory
      result.paths.setLen(0)
      return

  result.paths.sort
  result.status = discoveryComplete
