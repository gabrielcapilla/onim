type
  LspEventKind* = enum
    lspMessageEvent
    lspBootstrapEvent
    lspSemanticEvent
    lspEndEvent

  LspEvent* = object
    kind*: LspEventKind
    payload*: string
