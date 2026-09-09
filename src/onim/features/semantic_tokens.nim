import ../index/source_index
import ../index/occurrences
import ../index/symbols
import ../syntax/tokens

type
  SemanticTokenKind* = enum
    semanticNamespace
    semanticType
    semanticFunction
    semanticVariable
    semanticProperty
    semanticString
    semanticKeyword
    semanticOperator

  SemanticToken* = object
    token*: uint32
    kind*: SemanticTokenKind

const semanticTokenTypeNames*: array[SemanticTokenKind, string] = [
  "namespace", "type", "function", "variable", "property", "string", "keyword",
  "operator",
]

proc symbolTokenKind(kind: SourceSymbolKind): SemanticTokenKind {.inline.} =
  case kind
  of symbolProc, symbolFunc, symbolIterator, symbolMethod, symbolConverter:
    semanticFunction
  of symbolMacro, symbolTemplate:
    semanticFunction
  of symbolType:
    semanticType
  of symbolVar, symbolLet, symbolConst:
    semanticVariable

proc semanticTokenKind(index: SourceIndex, tokenIndex: int): SemanticTokenKind =
  let token = index.parsed.tokens[tokenIndex]
  if token.kind == tkString:
    return semanticString
  if token.kind != tkIdentifier:
    return semanticOperator
  if isNimKeyword(token):
    return semanticKeyword
  let symbolIndex = index.symbols.symbolToken(uint32(tokenIndex))
  if symbolIndex >= 0:
    return symbolTokenKind(index.symbols[symbolIndex].kind)
  let roles = index.occurrences.rolesForToken(uint32(tokenIndex))
  if occurrenceMember in roles:
    return semanticProperty
  if occurrenceQualifier in roles:
    return semanticNamespace
  semanticVariable

proc semanticTokens*(index: SourceIndex): seq[SemanticToken] =
  if index == nil:
    return
  for tokenIndex, token in index.parsed.tokens:
    if token.kind == tkString or (
      token.kind == tkPunctuation and operatorPunctuation(index.parsed.tokens, token)
    ) or (token.kind == tkIdentifier and validIdentifier(token)):
      result.add SemanticToken(
        token: uint32(tokenIndex), kind: semanticTokenKind(index, tokenIndex)
      )
