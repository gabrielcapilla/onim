import std/[algorithm, unittest]
import std/os except FileId

import onim/session/ids
import onim/session/module_catalog

proc cleanTree(root: string) =
  if not dirExists(root):
    return
  var directories: seq[string] = @[]
  for path in walkDirRec(root):
    if fileExists(path):
      removeFile(path)
    elif dirExists(path):
      directories.add path
  directories.sort(
    proc(left, right: string): int =
      cmp(right.len, left.len)
  )
  for path in directories:
    if dirExists(path):
      removeDir(path)
  if dirExists(root):
    removeDir(root)

suite "module catalog":
  test "indexes roots and reports deterministic resolution states":
    let root = getTempDir() / ("onim-module-catalog-" & $getCurrentProcessId())
    cleanTree(root)
    createDir(root)
    createDir(root / "src")
    createDir(root / "src" / "pkg")
    createDir(root / "lib")
    defer:
      cleanTree(root)

    let mainPath = root / "main.nim"
    let nestedPath = root / "src" / "pkg" / "provider.nim"
    let srcPath = root / "src" / "provider.nim"
    let libPath = root / "lib" / "provider.nim"
    writeFile(mainPath, "discard\n")
    writeFile(nestedPath, "discard\n")
    writeFile(srcPath, "discard\n")
    writeFile(libPath, "discard\n")
    writeFile(root / "package.nimble", "srcDir = \"lib\"\n")

    let files = @[
      ModuleFile(id: FileId(1), path: mainPath),
      ModuleFile(id: FileId(2), path: nestedPath),
      ModuleFile(id: FileId(3), path: srcPath),
      ModuleFile(id: FileId(4), path: libPath),
    ]
    let catalog = buildModuleCatalog(root, files)
    check catalog.valid
    check catalog.complete
    check catalog.rootCount == 3
    check catalog.moduleForPath(nestedPath) == "pkg/provider"
    check catalog.moduleForPath(srcPath) == "provider"
    check catalog.moduleForPath(libPath) == "provider"
    check catalog.candidateCount("provider") == 2

    check catalog.resolve(mainPath, "provider").kind == moduleResolved
    check catalog.resolve(mainPath, "provider").id.value == 3
    check catalog.resolveModuleName("other/consumer", "provider").kind == moduleAmbiguous
    check catalog.resolveModuleName("pkg/consumer", "./provider").kind == moduleResolved
    check catalog.resolveModuleName("pkg/consumer", "./provider").module ==
      "pkg/provider"
    check catalog.resolve(mainPath, "missing").kind == moduleMissing

  test "uses static nim.cfg paths and stays conservative for config.nims":
    let root = getTempDir() / ("onim-module-config-" & $getCurrentProcessId())
    cleanTree(root)
    createDir(root)
    createDir(root / "extra")
    defer:
      cleanTree(root)

    let extraPath = root / "extra" / "configured.nim"
    writeFile(extraPath, "discard\n")
    writeFile(root / "nim.cfg", "--path:extra\n")
    let configured =
      buildModuleCatalog(root, @[ModuleFile(id: FileId(1), path: extraPath)])
    check configured.complete
    check configured.moduleForPath(extraPath) == "configured"
    check configured.resolve(root / "main.nim", "configured").kind == moduleResolved

    writeFile(root / "config.nims", "switch(\"path\", \"dynamic\")\n")
    let unknown =
      buildModuleCatalog(root, @[ModuleFile(id: FileId(1), path: extraPath)])
    check not unknown.complete
    check unknown.resolve(root / "main.nim", "configured").kind == moduleUnknown
