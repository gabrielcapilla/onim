import ../index/cache_wire

type DiscoveryBudget* = object
  limit: uint32
  files: uint32
  directories: uint32
  entries: uint32

proc initDiscoveryBudget*(limit: uint32 = uint32(maxRecordCount)): DiscoveryBudget =
  result.limit = limit

proc capacity*(budget: DiscoveryBudget): uint32 {.inline.} =
  budget.limit

proc admitEntry*(budget: var DiscoveryBudget): bool {.inline.} =
  if budget.entries >= budget.limit:
    return false
  inc budget.entries
  true

proc admitFile*(budget: var DiscoveryBudget): bool {.inline.} =
  if budget.files >= budget.limit:
    return false
  inc budget.files
  true

proc admitDirectory*(budget: var DiscoveryBudget): bool {.inline.} =
  if budget.directories >= budget.limit:
    return false
  inc budget.directories
  true
