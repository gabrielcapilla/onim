import std/strutils

import ../index/surfaces
import ../stdlib/map

proc stdlibModuleName*(stdlib: StdlibMap, reference: string): string =
  if stdlib == nil or not stdlib.surfaceIsComplete:
    return
  let surface = stdlib.surfaceIndex()
  if surface == nil or not surface.valid or not surface.universeIsComplete:
    return
  let canonical = canonicalSurfaceModule(reference)
  if canonical.startsWith("std/") and surface.moduleKnown(canonical):
    return canonical
  if canonical.len > 0 and not canonical.startsWith("std/") and canonical.find('/') < 0:
    let stdModule = "std/" & canonical
    if surface.moduleKnown(stdModule):
      return stdModule
