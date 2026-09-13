type
  CompletionState* = enum
    completionUnsupported
    completionAvailable

  CompletionKind* = enum
    completionVariable
    completionConstant
    completionFunction
    completionMethod
    completionField
    completionType

  CompletionItem* = object
    label*: string
    kind*: CompletionKind
    snippetText*: string
    detail*: string
    documentation*: string
    filterText*: string
    sortText*: string
    recovered*: bool
    autoImportModule*: string

  CompletionResult* = object
    state*: CompletionState
    needsBootstrap*: bool
    insertStart*: int
    insertEnd*: int
    replaceStart*: int
    replaceEnd*: int
    items*: seq[CompletionItem]
