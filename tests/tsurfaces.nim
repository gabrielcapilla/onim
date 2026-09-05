import std/[os, sequtils, tables, unittest]

import onim/index/source_index
import onim/index/surfaces
import onim/index/symbols
import onim/stdlib/map
import onim/session/ids as onimIds

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

    var allMembers: seq[BindingCandidate] = @[]
    check index.appendBindingsInModule("std/alpha", "", allMembers)
    check allMembers.mapIt(it.name) == @["Foo_Bar", "split"]
    var fooMembers: seq[BindingCandidate] = @[]
    check index.appendBindingsInModule("std/alpha", "Foo", fooMembers)
    check fooMembers.mapIt(it.name) == @["Foo_Bar"]
    var unchanged = @[allMembers[0]]
    check not index.appendBindingsInModule("std/missing", "", unchanged)
    check unchanged.len == 1

    let uncertain = buildSurfaceIndex(
      @[
        SurfaceInput(
          module: "std/uncertain",
          origin: surfaceStdlib,
          uncertainty: {surfaceConditional},
          exports: @[exported("member", symbolProc)],
        )
      ],
      universeComplete = true,
    )
    var uncertainDestination = @[allMembers[0]]
    check not uncertain.appendBindingsInModule(
      "std/uncertain", "", uncertainDestination
    )
    check uncertainDestination.len == 1

    let incomplete = buildSurfaceIndex(
      @[SurfaceInput(module: "std/incomplete", origin: surfaceStdlib)],
      universeComplete = false,
    )
    var incompleteDestination = @[allMembers[0]]
    check not incomplete.appendBindingsInModule(
      "std/incomplete", "", incompleteDestination
    )
    check incompleteDestination.len == 1

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

  test "resolves owner-relative modules without merging duplicate leaves":
    let index = buildSurfaceIndex(
      @[
        SurfaceInput(module: "pkg/provider", origin: surfaceProject),
        SurfaceInput(module: "other/provider", origin: surfaceProject),
      ],
      universeComplete = true,
    )
    check index.moduleForReference("provider", "pkg/consumer") == "pkg/provider"
    check index.moduleForReference("provider", "other/consumer") == "other/provider"
    check index.moduleForReference("provider", "main") == ""

  test "converts exported source declarations into the same surface":
    let source = indexSource("proc answer*()\n")
    let input = projectSurfaceInput("project/main", source)
    check input.exports.len == 1
    check input.exports[0].name == "answer"
    let index = buildSurfaceIndex(@[input], universeComplete = true)
    check index.valid
    check index.universeIsComplete
    check index.lookup("answer").kind == surfaceResolved
    check index.lookup("private").kind == surfaceUnresolved

  test "rebuilds project generations without mutating predecessors":
    let first = buildProjectSurfaceIndex(
      @[
        SurfaceContributor(
          fileId: onimIds.FileId(1),
          contentGeneration: onimIds.ContentGeneration(1),
          input: SurfaceInput(
            module: "project/first",
            origin: surfaceProject,
            exports: @[exported("answer", symbolProc)],
          ),
        ),
        SurfaceContributor(
          fileId: onimIds.FileId(2),
          contentGeneration: onimIds.ContentGeneration(1),
          input: SurfaceInput(
            module: "project/second",
            origin: surfaceProject,
            exports: @[exported("other", symbolProc)],
          ),
        ),
      ],
      universeComplete = true,
    )
    let second = buildProjectSurfaceIndex(
      @[
        SurfaceContributor(
          fileId: onimIds.FileId(1),
          contentGeneration: onimIds.ContentGeneration(1),
          input: SurfaceInput(
            module: "project/first",
            origin: surfaceProject,
            exports: @[exported("answer", symbolProc)],
          ),
        ),
        SurfaceContributor(
          fileId: onimIds.FileId(2),
          contentGeneration: onimIds.ContentGeneration(2),
          input: SurfaceInput(
            module: "project/second",
            origin: surfaceProject,
            exports: @[exported("changed", symbolProc)],
          ),
        ),
      ],
      universeComplete = true,
      previous = first,
    )
    check first.validateSurfaceIndex
    check second.validateSurfaceIndex
    check first.lookup("other").kind == surfaceResolved
    check first.lookup("changed").kind == surfaceUnresolved
    check second.lookup("other").kind == surfaceUnresolved
    check second.lookup("changed").kind == surfaceResolved
    check second.lookup("answer").kind == surfaceResolved

  test "uses the complete generated map without fallback rows":
    let stdlib = loadStdlibMap("")
    check stdlib.surfaceIsComplete
    let surface = stdlib.surfaceIndex()
    check surface.valid
    check surface.universeIsComplete
    check stdlib.implicitModule("std/system")
    let walkDir = surface.lookupInModule("std/os", "walkDir")
    check walkDir.kind == surfaceResolved
    check walkDir.candidates.len == 1
    check surface.exportsFor(walkDir.candidates[0]).len >= 2
    for candidate in stdlib.symbols["walkDir"]:
      check not (candidate.module == "std/os" and candidate.signature.len == 0)

  test "keeps fallback data conservative":
    let fallback = emptyStdlibMap()
    let surface = fallback.surfaceIndex()
    check surface.valid
    check not surface.universeIsComplete
    check surface.lookup("walkDir").kind == surfaceUnknown

  test "rejects malformed generated data as incomplete fallback":
    let invalidPath = getTempDir() / "onim-invalid-stdlib-map.json"
    writeFile(invalidPath, "{")
    let fallback = loadStdlibMap(invalidPath)
    removeFile(invalidPath)
    let surface = fallback.surfaceIndex()
    check surface.valid
    check not surface.universeIsComplete
    check surface.lookup("walkDir").kind == surfaceUnknown
