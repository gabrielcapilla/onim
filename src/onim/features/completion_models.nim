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

  CompletionResult* = object
    state*: CompletionState
    replaceStart*: int
    replaceEnd*: int
    items*: seq[CompletionItem]
