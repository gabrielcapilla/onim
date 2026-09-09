import std/tables

import ../index/source_index
import ./disk_source
import ./ids
import ./workspace_models

proc markMissingDiscoveredFiles*(
    files: var seq[FileRecord],
    present: Table[string, bool],
    hadRecords: bool,
    nextContentGeneration: var uint64,
): bool =
  for file in files.mitems:
    if file.state != workspaceOpen and not present.hasKey(file.path) and
        file.state != workspaceMissing:
      file.state = workspaceMissing
      file.text = ""
      file.textLoaded = true
      file.stamp = unknownStamp()
      file.index = indexSource("")
      file.contentGeneration = takeContentGeneration(nextContentGeneration)
      if hadRecords:
        result = true
