import std/json

import ../semantic/compiler_api
import ../semantic/native_diagnostics
import ./positions
import ./transport

proc nativeDiagnosticMessage(diagnostic: NativeDiagnostic): string =
  case diagnostic.kind
  of nativeMalformedIdentifier:
    "malformed identifier"
  of nativeUnclosedString:
    "unterminated string literal"
  of nativeUnexpectedDelimiter:
    "unexpected closing delimiter"
  of nativeUnclosedDelimiter:
    "unclosed delimiter"
  of nativeUndeclaredIdentifier:
    "undeclared identifier: " & diagnostic.name
  of nativeMissingStdlibImport:
    "missing import: " & diagnostic.module
  of nativeMissingProjectImport:
    "missing project import: " & diagnostic.module
  of nativeTypo:
    "unknown identifier: " & diagnostic.name & "; did you mean " & diagnostic.suggestion &
      "?"

proc compilerDeclarationRange(
    source: string, diagnostic: CompilerDiagnostic
): tuple[startOffset, endOffset: int] =
  if not diagnostic.isUnusedDeclaration or diagnostic.name.len == 0 or
      diagnostic.line < 0 or diagnostic.column < 0:
    return (-1, -1)
  var line = 0
  var offset = 0
  while line < diagnostic.line:
    var newline = offset
    while newline < source.len and source[newline] != '\n':
      inc newline
    if newline >= source.len:
      return (-1, -1)
    offset = newline + 1
    inc line
  let startOffset = offset + diagnostic.column
  let endOffset = startOffset + diagnostic.name.len
  if startOffset < offset or endOffset > source.len:
    return (-1, -1)
  if source[startOffset ..< endOffset] == diagnostic.name:
    return (startOffset, endOffset)
  if source[startOffset] != '`':
    return (-1, -1)
  let nameStart = startOffset + 1
  let nameEnd = nameStart + diagnostic.name.len
  if nameEnd >= source.len or source[nameStart ..< nameEnd] != diagnostic.name or
      source[nameEnd] != '`':
    return (-1, -1)
  (startOffset, nameEnd + 1)

proc diagnosticsPayload*(
    uri, source: string,
    diagnostics: seq[NativeDiagnostic],
    compilerDiagnostics: seq[CompilerDiagnostic] = @[],
    version: int64 = -1,
): JsonNode =
  let positions = initPositionIndex(source)
  var values = newJArray()
  for diagnostic in diagnostics:
    var range = newJObject()
    range["start"] = positionAt(positions, source, diagnostic.startOffset)
    range["end"] = positionAt(positions, source, diagnostic.endOffset)
    var value = newJObject()
    value["range"] = range
    value["severity"] = %1
    value["source"] = %"onim"
    value["message"] = %nativeDiagnosticMessage(diagnostic)
    if diagnostic.kind == nativeTypo:
      value["code"] = %"onim.typo"
      value["data"] =
        %*{"original": diagnostic.name, "replacement": diagnostic.suggestion}
    values.add value

  for diagnostic in compilerDiagnostics:
    let span = compilerDeclarationRange(source, diagnostic)
    if span.startOffset < 0:
      continue
    var range = newJObject()
    range["start"] = positionAt(positions, source, span.startOffset)
    range["end"] = positionAt(positions, source, span.endOffset)
    values.add %*{
      "range": range,
      "severity": 2,
      "tags": [1],
      "code": "XDeclaredButNotUsed",
      "source": "onim",
      "message": diagnostic.message,
    }

  var params = newJObject()
  params["uri"] = %uri
  if version >= 0:
    params["version"] = %version
  params["diagnostics"] = values
  var message = newJObject()
  message["jsonrpc"] = %"2.0"
  message["method"] = %"textDocument/publishDiagnostics"
  message["params"] = params
  message

proc sendDiagnostics*(
    uri, source: string,
    diagnostics: seq[NativeDiagnostic],
    compilerDiagnostics: seq[CompilerDiagnostic] = @[],
    version: int64 = -1,
) =
  sendMessage(
    diagnosticsPayload(uri, source, diagnostics, compilerDiagnostics, version)
  )
