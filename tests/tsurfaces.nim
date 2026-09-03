import std/[os, tables, unittest]

import onim/index/source_index
import onim/index/surfaces
import onim/index/symbols
import onim/stdlib/map

proc exported(
    name: string, kind: SourceSymbolKind, arity: int32 = -1, signature = ""
): SurfaceExportInput =
  SurfaceExportInput(
    name: name,
    kind: kind,
    kindKnown: true,
    declaredArity: arity,
    signature: signature,
    shapeKnown: arity >= 0 or signature.len > 0,
  )

suite "native module surfaces":
  test "sorts modules and groups overloads deterministically":
    let index = buildSurfaceIndex(
      @[
        SurfaceInput(
          module: "std/zeta",
          origin: surfaceStdlib,
          exports: @[exported("split", symbolProc, 2, "zeta")],
        ),
        SurfaceInput(
          module: "std/alpha",
          origin: surfaceStdlib,
          exports: @[
            exported("Foo_Bar", symbolProc, 1, "one"),
            exported("Foo_Bar", symbolProc, 2, "two"),
            exported("split", symbolProc, 2, "alpha"),
          ],
        ),
      ],
      universeComplete = true,
    )
    check index.valid
    check index.universeIsComplete
    check index.validateSurfaceIndex
    check index.moduleCount == 2
    check index.bindingCount == 3
    check index.exportCount == 4
    check index.moduleAt(SurfaceId(1)).module == "std/alpha"
    check index.moduleAt(SurfaceId(2)).module == "std/zeta"

    let grouped = index.lookupInModule("std/alpha", "FooBar")
    check grouped.kind == surfaceResolved
    check grouped.candidates.len == 1
    check index.exportsFor(grouped.candidates[0]).len == 2

    let collision = index.lookup("split")
    check collision.kind == surfaceAmbiguous
    check collision.candidates.len == 2
    check index.moduleAt(collision.candidates[0].surface).module == "std/alpha"
    check index.moduleAt(collision.candidates[1].surface).module == "std/zeta"

  test "marks uncertain modules as unknown instead of guessing":
    let index = buildSurfaceIndex(
      @[
        SurfaceInput(
          module: "project/conditional",
          origin: surfaceProject,
          uncertainty: {surfaceConditional},
          exports: @[exported("answer", symbolConst)],
        )
      ],
      universeComplete = true,
    )
    check index.valid
    check not index.universeIsComplete
    check index.lookup("answer").kind == surfaceUnknown
    check index.lookup("missing").kind == surfaceUnknown

  test "converts exported source declarations into the same surface":
    let source = indexSource("proc answer*()\n")
    let input = projectSurfaceInput("project/main", source)
    check input.exports.len == 1
    check input.exports[0].name == "answer"
    let index = buildSurfaceIndex(@[input], universeComplete = true)
    check index.valid
    check index.lookup("answer").kind == surfaceUnknown
    check index.lookup("private").kind == surfaceUnknown

  test "uses the complete generated map without fallback rows":
    let stdlib = loadStdlibMap("")
    check stdlib.surface.valid
    check stdlib.surface.universeIsComplete
    let walkDir = stdlib.surface.lookupInModule("std/os", "walkDir")
    check walkDir.kind == surfaceResolved
    check walkDir.candidates.len == 1
    check stdlib.surface.exportsFor(walkDir.candidates[0]).len >= 2
    for candidate in stdlib.symbols["walkDir"]:
      check not (candidate.module == "std/os" and candidate.signature.len == 0)

  test "keeps fallback data conservative":
    let fallback = emptyStdlibMap()
    check fallback.surface.valid
    check not fallback.surface.universeIsComplete
    check fallback.surface.lookup("walkDir").kind == surfaceUnknown

  test "rejects malformed generated data as incomplete fallback":
    let invalidPath = getTempDir() / "onim-invalid-stdlib-map.json"
    writeFile(invalidPath, "{")
    let fallback = loadStdlibMap(invalidPath)
    removeFile(invalidPath)
    check fallback.surface.valid
    check not fallback.surface.universeIsComplete
    check fallback.surface.lookup("walkDir").kind == surfaceUnknown
