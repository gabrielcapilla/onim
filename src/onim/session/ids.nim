type
  FileId* = distinct uint32
  SnapshotId* = distinct uint64
  ContentGeneration* = distinct uint64
  DependencyGeneration* = distinct uint64
  ConfigGeneration* = distinct uint64
  SurfaceGeneration* = distinct uint64

const
  InvalidFileId* = FileId(0'u32)
  InvalidSnapshotId* = SnapshotId(0'u64)
  InvalidContentGeneration* = ContentGeneration(0'u64)
  InvalidDependencyGeneration* = DependencyGeneration(0'u64)
  InvalidConfigGeneration* = ConfigGeneration(0'u64)
  InvalidSurfaceGeneration* = SurfaceGeneration(0'u64)

proc value*(id: FileId): uint32 =
  uint32(id)

proc value*(id: SnapshotId): uint64 =
  uint64(id)

proc value*(generation: ContentGeneration): uint64 =
  uint64(generation)

proc value*(generation: DependencyGeneration): uint64 =
  uint64(generation)

proc value*(generation: ConfigGeneration): uint64 =
  uint64(generation)

proc value*(generation: SurfaceGeneration): uint64 =
  uint64(generation)

proc slot*(id: FileId): int =
  if uint32(id) == 0'u32:
    -1
  else:
    int(uint32(id)) - 1

proc valid*(id: FileId): bool =
  uint32(id) != 0'u32
