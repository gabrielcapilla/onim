import ./module_catalog
import ./workspace_models

proc buildWorkspaceModuleCatalog*(
    root: string, files: openArray[FileRecord]
): ModuleCatalog =
  var moduleFiles = newSeqOfCap[ModuleFile](files.len)
  for file in files:
    if file.state != workspaceMissing:
      moduleFiles.add ModuleFile(id: file.id, path: file.path)
  buildModuleCatalog(root, moduleFiles)
