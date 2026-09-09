import std/atomics

import ../semantic/worker
import ../session/bootstrap_worker
import ../session/ids
import ./lsp_events as lspEventTypes
import ./message_parsing
import ./transport

var lspEvents*: Channel[LspEvent]
var lspSemanticStopRequested*: Atomic[bool]

proc readInputEvents*() {.thread, gcsafe.} =
  while true:
    let payload = readMessageText()
    if payload.len == 0:
      lspEvents.send(LspEvent(kind: lspEndEvent))
      break
    let exitPayload = isExitPayload(payload)
    lspEvents.send(LspEvent(kind: lspMessageEvent, payload: payload))
    if exitPayload:
      break

proc bootstrapEventBridge*() {.thread, gcsafe.} =
  while true:
    let value = receiveBootstrap()
    lspEvents.send(
      LspEvent(kind: lspBootstrapEvent, payload: encodeBootstrapResult(value))
    )
    if value.kind == bootstrapStopped:
      break

proc semanticEventBridge*() {.thread, gcsafe.} =
  while true:
    let value = receiveSemantic()
    if value.failed and not value.fileId.valid and
        lspSemanticStopRequested.load(moRelaxed):
      break
    lspEvents.send(
      LspEvent(kind: lspSemanticEvent, payload: encodeSemanticResult(value))
    )
    if value.failed and not value.fileId.valid:
      break
