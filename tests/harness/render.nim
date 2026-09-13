import std/strutils

import onim/features/completion_models
import onim/features/definition_models
import onim/features/hover
import onim/features/organize_edits
import onim/features/references
import onim/session/ids
import onim/semantic/native_diagnostics

proc renderText(value: string): string {.inline.} =
  value.replace("\\", "\\\\").replace("\r", "\\r").replace("\n", "\\n")

proc renderCompletion*(value: CompletionResult): string =
  result =
    "state=" & $value.state & " range=" & $value.replaceStart & ":" & $value.replaceEnd
  for item in value.items:
    result.add "\n"
    result.add "item label=" & renderText(item.label) & " kind=" & $item.kind
    result.add " detail=" & renderText(item.detail)
    result.add " documentation=" & renderText(item.documentation)
    result.add " filter=" & renderText(item.filterText)
    result.add " sort=" & renderText(item.sortText)
    result.add " recovered=" & $item.recovered
    result.add " autoImport=" & renderText(item.autoImportModule)

proc renderHover*(value: HoverInfo): string =
  "state=" & $value.state & " name=" & renderText(value.name) & " module=" &
    renderText(value.module) & " kind=" & renderText(value.kind) & " signature=" &
    renderText(value.signature) & " documentation=" & renderText(value.documentation) &
    " range=" & $value.rangeStartOffset & ":" & $value.rangeEndOffset &
    " declarationLine=" & $value.declarationLine & " declaration=" &
    renderText(value.declarationText)

proc renderDefinition*(value: DefinitionResolution): string =
  "state=" & $value.kind & " target=" & $value.target.kind & " file=" &
    $value.target.fileId.value & " snapshot=" & $value.target.snapshotId.value &
    " generation=" & $value.target.contentGeneration.value & " token=" &
    $value.target.nameToken

proc renderReferences*(value: ReferencesResult): string =
  result =
    "supported=" & $value.supported & " target=" &
    renderDefinition(
      DefinitionResolution(kind: definitionResolved, target: value.target)
    )
  for match in value.matches:
    result.add "\nmatch file=" & $match.fileId.value & " generation=" &
      $match.contentGeneration.value & " token=" & $match.tokenIndex

proc renderDiagnostics*(values: openArray[NativeDiagnostic]): string =
  for index, value in values:
    if index > 0:
      result.add "\n"
    result.add "kind=" & $value.kind & " range=" & $value.startOffset & ":" &
      $value.endOffset & " name=" & renderText(value.name) & " module=" &
      renderText(value.module) & " suggestion=" & renderText(value.suggestion)

proc renderEdits*(values: openArray[ImportEdit]): string =
  for index, value in values:
    if index > 0:
      result.add "\n"
    result.add "range=" & $value.startOffset & ":" & $value.endOffset & " text=" &
      renderText(value.newText)
