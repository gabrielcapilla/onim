import std/[os, osproc, strutils]

type FeatureSession* = ref object
  process*: Process
  root*: string
  filePath*: string
  uri*: string
  definitionUri*: string

proc startFeatureSession*(root: string): FeatureSession =
  new(result)
  result.root = root
  result.filePath = root / "tests" / "before" / "walkdir.nim"
  result.uri = "file://" & result.filePath.replace('\\', '/')
  result.definitionUri = "file:///tmp/onim-definition.nim"
  result.process = startProcess(root / "onim", args = ["--stdio"], workingDir = root)

proc closeFeatureSession*(session: FeatureSession) =
  if session != nil and session.process != nil:
    close session.process
