import ../index/source_index
import ./disk_source
import ./workspace_models

proc indexWorkspaceText*(
    root, path, source, previousSource: string,
    previousIndex: SourceIndex,
    state: WorkspaceFileState,
): SourceIndex =
  case state
  of workspaceOnDisk:
    indexDiskSource(root, path, source)
  of workspaceOpen:
    let incremental = tryIndexSourceIncremental(previousSource, previousIndex, source)
    if incremental != nil:
      incremental
    else:
      indexSource(source)
  of workspaceMissing:
    indexSource(source)
