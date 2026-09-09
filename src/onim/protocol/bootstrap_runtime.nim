import ../session/bootstrap_worker
import ../session/workspace
import ../stdlib/map
import ./diagnostic_publish
import ./pending_workspace

type BootstrapRuntime* = object
  active*: bool
  hasPending*: bool
  nextJobGeneration*: uint64
  pending*: BootstrapRequest

proc scheduleBootstrap*(runtime: var BootstrapRuntime, workspace: Workspace): bool =
  if workspace == nil or workspace.root.len == 0:
    return
  inc runtime.nextJobGeneration
  let request = BootstrapRequest(
    jobGeneration: runtime.nextJobGeneration,
    workspaceGeneration: workspace.workspaceGeneration(),
    configGeneration: workspace.configurationGeneration,
    root: workspace.root,
  )
  if runtime.active:
    runtime.pending = request
    runtime.hasPending = true
    cancelBootstrap(request.jobGeneration)
    return true
  elif submitBootstrap(request):
    runtime.active = true
    return true
  false

proc handleBootstrapEvent*(
    runtime: var BootstrapRuntime,
    workspace: Workspace,
    pendingWorkspace: var seq[PendingWorkspaceRequest],
    stdlib: StdlibMap,
    payload: string,
    traceEnabled: bool,
): bool =
  let value = decodeBootstrapResult(payload)
  runtime.active = false
  let accepted = workspace.applyBootstrap(value)
  if accepted:
    publishOpenNativeDiagnostics(workspace, stdlib, traceEnabled)
    finishPendingWorkspace(workspace, pendingWorkspace)
  elif value.kind == bootstrapFailed:
    finishPendingWorkspace(workspace, pendingWorkspace)
  if runtime.hasPending:
    let request = runtime.pending
    runtime.hasPending = false
    if submitBootstrap(request):
      runtime.active = true
  accepted
