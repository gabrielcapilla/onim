import ../semantic/compiler_api
import ../semantic/native_diagnostics
import ../features/typo
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
    compilerDiagnostics: seq[CompilerDiagnostic] = @[],
) =
  let uri =
    if snapshot.uri.len > 0:
      snapshot.uri
    else:
      fileUri(snapshot.path)
  if uri.len == 0:
    return
  var diagnostics =
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
  if snapshot.valid and snapshot.index != nil:
    for match in typoMatches(workspace, snapshot, stdlib):
      diagnostics.add NativeDiagnostic(
        kind: nativeTypo,
        startOffset: match.startOffset,
        endOffset: match.endOffset,
        name: match.name,
        suggestion: match.suggestion,
      )
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
  sendDiagnostics(
    uri, snapshot.text, diagnostics, compilerDiagnostics, snapshot.version
  )

proc clearNativeDiagnostics*(uri: string, traceEnabled: bool) =
  if uri.len > 0:
    traceLsp(
      traceEnabled, "clearDiagnostics", uri, -1, InvalidSnapshotId, InvalidFileId,
      InvalidContentGeneration, InvalidDependencyGeneration, -1, 0,
    )
    sendDiagnostics(uri, "", @[])

proc publishOpenNativeDiagnostics*(
    workspace: Workspace, stdlib: StdlibMap, traceEnabled: bool
) =
  for id in workspace.openDocumentIds:
    let snapshot = workspace.snapshotForFile(id)
    publishNativeDiagnostics(
      workspace, snapshot, stdlib, diagnosticBootstrap, traceEnabled
    )
