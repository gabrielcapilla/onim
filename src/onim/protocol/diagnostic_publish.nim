import ../semantic/native_diagnostics
import ../session/ids
import ../session/workspace
import ../session/workspace_models
import ../stdlib/map
import ./diagnostics
import ./tracing
import ./uris

type DiagnosticPublishReason* = enum
  diagnosticOpen
  diagnosticEdit
  diagnosticBootstrap

proc publishNativeDiagnostics*(
    workspace: Workspace,
    snapshot: WorkspaceSnapshot,
    stdlib: StdlibMap,
    reason: DiagnosticPublishReason,
    traceEnabled: bool,
) =
  let uri =
    if snapshot.uri.len > 0:
      snapshot.uri
    else:
      fileUri(snapshot.path)
  if uri.len == 0:
    return
  let diagnostics =
    if snapshot.valid and snapshot.index != nil:
      nativeDiagnostics(
        snapshot.index,
        stdlib,
        if workspace.graphComplete:
          workspace.projectSurface()
        else:
          nil,
        workspace.moduleForPath(snapshot.path),
        workspace.moduleCatalog(),
      )
    else:
      @[]
  traceLsp(
    traceEnabled,
    "publishDiagnostics",
    uri,
    snapshot.version,
    snapshot.id,
    snapshot.fileId,
    snapshot.contentGeneration,
    snapshot.dependencyGeneration,
    ord(reason),
    diagnostics.len,
  )
  if diagnostics.len == 0 and workspace.bootstrapState != workspaceBootstrapComplete and
      reason == diagnosticOpen:
    return
  sendNativeDiagnostics(uri, snapshot.text, diagnostics, snapshot.version)

proc clearNativeDiagnostics*(uri: string, traceEnabled: bool) =
  if uri.len > 0:
    traceLsp(
      traceEnabled, "clearDiagnostics", uri, -1, InvalidSnapshotId, InvalidFileId,
      InvalidContentGeneration, InvalidDependencyGeneration, -1, 0,
    )
    sendNativeDiagnostics(uri, "", @[])

proc publishOpenNativeDiagnostics*(
    workspace: Workspace, stdlib: StdlibMap, traceEnabled: bool
) =
  for id in workspace.openDocumentIds:
    let snapshot = workspace.snapshotForFile(id)
    publishNativeDiagnostics(
      workspace, snapshot, stdlib, diagnosticBootstrap, traceEnabled
    )
