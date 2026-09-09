import std/json

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

proc sendNativeDiagnostics*(
    uri, source: string, diagnostics: seq[NativeDiagnostic], version: int64 = -1
) =
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
    values.add value

  var params = newJObject()
  params["uri"] = %uri
  if version >= 0:
    params["version"] = %version
  params["diagnostics"] = values
  var message = newJObject()
  message["jsonrpc"] = %"2.0"
  message["method"] = %"textDocument/publishDiagnostics"
  message["params"] = params
  sendMessage(message)
