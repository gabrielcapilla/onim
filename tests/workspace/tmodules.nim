import std/[strutils, unittest]
import std/os except FileId

import onim/session/ids
import onim/session/discovery_budget
import onim/session/module_catalog
import onim/session/package_catalog
import harness/workspace_fs

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

  test "indexes local Nimble dependencies without executing config":
    let root = getTempDir() / ("onim-module-nimbledeps-" & $getCurrentProcessId())
    cleanTree(root)
    createDir(root)
    createDir(root / "nimbledeps")
    createDir(root / "nimbledeps" / "vendor-0.1.0")
    createDir(root / "nimbledeps" / "vendor-0.1.0" / "src")
    createDir(root / "nimbledeps" / "plain-0.1.0")
    defer:
      cleanTree(root)

    let modulePath = root / "nimbledeps" / "vendor-0.1.0" / "src" / "vendor.nim"
    let plainPath = root / "nimbledeps" / "plain-0.1.0" / "plain.nim"
    writeFile(
      root / "nimbledeps" / "vendor-0.1.0" / "vendor.nimble", "srcDir = \"src\"\n"
    )
    writeFile(
      root / "nimbledeps" / "plain-0.1.0" / "plain.nimble", "version = \"0.1.0\"\n"
    )
    writeFile(modulePath, "proc value*(): int = 1\n")
    writeFile(plainPath, "proc value*(): int = 1\n")

    let catalog = buildModuleCatalog(
      root,
      @[
        ModuleFile(id: FileId(1), path: modulePath),
        ModuleFile(id: FileId(2), path: plainPath),
      ],
    )
    check catalog.complete
    check catalog.moduleForPath(modulePath) == "vendor"
    check catalog.moduleForPath(plainPath) == "plain"
    check catalog.resolve(root / "main.nim", "vendor").kind == moduleResolved
    check catalog.resolve(root / "main.nim", "plain").kind == moduleResolved

  test "resolves only declared installed Nimble packages":
    let root = getTempDir() / ("onim-module-installed-" & $getCurrentProcessId())
    let nimbleRoot = getTempDir() / ("onim-nimble-store-" & $getCurrentProcessId())
    cleanTree(root)
    cleanTree(nimbleRoot)
    createDir(root)
    createDir(nimbleRoot / "pkgs2")
    createDir(nimbleRoot / "pkgs2" / "sample-1.0.0-hash" / "src")
    createDir(nimbleRoot / "pkgs2" / "sample-2.0.0-hash" / "src")
    defer:
      cleanTree(root)
      cleanTree(nimbleRoot)

    writeFile(root / "project.nimble", "requires \"sample >= 1.0\"\n")
    for version in ["1.0.0", "2.0.0"]:
      let packageRoot = nimbleRoot / "pkgs2" / ("sample-" & version & "-hash")
      writeFile(
        packageRoot / "sample.nimble",
        "version = \"" & version & "\"\nsrcDir = \"src\"\n",
      )
      writeFile(packageRoot / "src" / "sample.nim", "proc value*() = discard\n")
    putEnv("NIMBLE_DIR", nimbleRoot)
    defer:
      delEnv("NIMBLE_DIR")

    let resolutions = declaredNimblePackages(root)
    check resolutions.len == 1
    check resolutions[0].kind == packageResolved
    check resolutions[0].selected.version == "2.0.0"
    check resolutions[0].selected.sourceRoot.endsWith("sample-2.0.0-hash/src")
    check nimbleDependencyRoots(root).len == 1

    var budget = initDiscoveryBudget(3)
    let bounded = nimbleDependencySourcesBounded(root, budget, nil)
    check bounded.limited
    check bounded.paths.len == 0

    writeFile(root / "project.nimble", "requires \"unlisted\"\n")
    let missing = declaredNimblePackages(root)
    check missing.len == 1
    check missing[0].kind == packageMissing

    createDir(nimbleRoot / "pkgs2" / "broken-1.0.0-hash")
    writeFile(
      nimbleRoot / "pkgs2" / "broken-1.0.0-hash" / "broken.nimble",
      "version = \"1.0.0\"\nsrcDir = \"missing\"\n",
    )
    writeFile(root / "project.nimble", "requires \"broken\"\n")
    let unknown = declaredNimblePackages(root)
    check unknown.len == 1
    check unknown[0].kind == packageUnknown
