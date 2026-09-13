import ../index/source_index
import ../index/bindings
import ../index/occurrences
import ../index/scope_queries
import ../index/scopes
import ../index/symbols
import ../index/type_kinds
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
    semanticNumber
    semanticParameter
    semanticMethod

  SemanticToken* = object
    token*: uint32
    kind*: SemanticTokenKind

const semanticTokenTypeNames*: array[SemanticTokenKind, string] = [
  "namespace", "type", "function", "variable", "property", "string", "keyword",
  "operator", "number", "parameter", "method",
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

proc isParameterToken(index: SourceIndex, tokenIndex: uint32): bool {.inline.} =
  let declarationIndex = index.scopes.declarationOrdinalAt(tokenIndex)
  if declarationIndex >= 0 and
      index.scopes.declarations[declarationIndex].kind == declarationParameter:
    return true
  let binding = index.resolveBinding(tokenIndex)
  if binding.state != bindingResolved:
    return false
  let parameterIndex = index.scopes.declarationOrdinalAt(binding.declarationToken)
  parameterIndex >= 0 and
    index.scopes.declarations[parameterIndex].kind == declarationParameter

proc isCallToken(index: SourceIndex, tokenIndex: int): bool {.inline.} =
  tokenIndex + 1 < index.parsed.tokens.len and
    index.parsed.tokens[tokenIndex + 1].kind == tkPunctuation and
    index.parsed.tokens.tokenTextEquals(index.parsed.tokens[tokenIndex + 1], "(")

proc semanticTokenKind(index: SourceIndex, tokenIndex: int): SemanticTokenKind =
  let token = index.parsed.tokens[tokenIndex]
  if token.kind == tkString:
    return semanticString
  if token.kind == tkNumber:
    return semanticNumber
  if token.kind != tkIdentifier:
    return semanticOperator
  if isNimKeyword(token):
    return semanticKeyword
  if index.isParameterToken(uint32(tokenIndex)):
    return semanticParameter
  let roles = index.occurrences.rolesForToken(uint32(tokenIndex))
  if occurrenceMember in roles:
    if index.isCallToken(tokenIndex):
      return semanticMethod
    return semanticProperty
  if occurrenceQualifier in roles:
    return semanticNamespace
  let declarationIndex = index.scopes.declarationOrdinalAt(uint32(tokenIndex))
  if declarationIndex >= 0 and
      index.scopes.declarations[declarationIndex].kind in
      {declarationLet, declarationVar, declarationConst}:
    return semanticVariable
  let binding = index.resolveBinding(uint32(tokenIndex))
  if binding.state != bindingUnknown:
    return semanticVariable
  let symbolIndex = index.symbols.symbolToken(uint32(tokenIndex))
  if symbolIndex >= 0:
    return symbolTokenKind(index.symbols[symbolIndex].kind)
  let name = index.parsed.tokens.tokenText(token)
  let moduleSymbol = index.symbols.lookupSymbol(index.parsed.tokens, name)
  if moduleSymbol >= 0:
    return symbolTokenKind(index.symbols[moduleSymbol].kind)
  if primitiveTypeKind(index.parsed.tokens, tokenIndex) != typeUnknown:
    return semanticType
  if index.isCallToken(tokenIndex):
    return semanticFunction
  semanticVariable

proc semanticTokens*(index: SourceIndex): seq[SemanticToken] =
  if index == nil:
    return
  for tokenIndex, token in index.parsed.tokens:
    if token.kind in {tkString, tkNumber} or (
      token.kind == tkPunctuation and operatorPunctuation(index.parsed.tokens, token)
    ) or (token.kind == tkIdentifier and validIdentifier(token)):
      result.add SemanticToken(
        token: uint32(tokenIndex), kind: semanticTokenKind(index, tokenIndex)
      )
