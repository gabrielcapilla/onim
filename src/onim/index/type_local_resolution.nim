import ../syntax/tokens
import ./scopes
import ./scope_queries
import ./symbols
import ./type_annotation_syntax
import ./type_declaration_syntax
import ./type_ids
import ./type_index_models
import ./type_interning
import ./type_kinds
import ./type_local_calls
import ./type_local_models
import ./type_expression_syntax
import ./type_queries
import ./type_states

proc localTypeAt*(
    types: TypeIndex, tokens: TokenStore, scopes: ScopeIndex, declarationToken: uint32
): LocalTypeInfo =
  if types.localTypeIds.len != scopes.declarations.len:
    return
  let declarationOrdinal = scopes.declarationOrdinalAt(declarationToken)
  if declarationOrdinal < 0 or declarationOrdinal >= scopes.declarations.len:
    return
  let declaration = scopes.declarations[declarationOrdinal]
  if declaration.pastToken > uint32(tokens.len):
    return
  let split = splitDeclaration(tokens, declaration)
  let descriptor = declarationTypeDescriptor(tokens, declaration)
  let expected = types.descriptorTypeId(descriptor)
  if expected == InvalidTypeId or types.localTypeIds[declarationOrdinal] != expected:
    return
  if split.colon >= 0:
    let past =
      if split.equals > split.colon:
        split.equals
      else:
        int(declaration.pastToken)
    if descriptor.kind == typeUnknown:
      return
    result.kind = descriptor.kind
    result.state = typeStateResolved
    result.form = localTypeFormAnnotation
    result.typeId = expected
    result.typeToken =
      if descriptor.kind == typeNamed:
        descriptor.nameToken
      elif descriptor.kind == typeRef:
        descriptor.baseNameToken
      elif descriptor.kind == typeGenericInstance:
        descriptor.nameToken
      elif descriptor.kind == typeSeq and descriptor.baseKind == typeNamed:
        descriptor.baseNameToken
      elif descriptor.kind == typeArray and descriptor.baseKind == typeNamed:
        descriptor.baseNameToken
      else:
        InvalidTypeToken
    result.firstToken = uint32(split.colon + 1)
    result.pastToken = uint32(past)
    return
  if split.equals < 0:
    return

  var call = directCallInfo(tokens, split.equals + 1, int(declaration.pastToken))
  if call.form == localTypeFormCall:
    call.typeId = expected
    return call

  result.kind = descriptor.kind
  if result.kind != typeUnknown:
    result.state = typeStateResolved
    result.form = localTypeFormLiteral
    result.typeId = expected
    result.typeToken =
      if descriptor.kind == typeNamed and descriptor.nameToken != declaration.nameToken:
        descriptor.nameToken
      elif descriptor.kind in {typeSeq, typeArray} and descriptor.baseKind == typeNamed:
        descriptor.baseNameToken
      else:
        InvalidTypeToken
    result.firstToken = uint32(split.equals + 1)
    result.pastToken = declaration.pastToken

proc moduleValueTypeAt*(
    types: TypeIndex, tokens: TokenStore, symbol: SourceSymbol
): LocalTypeInfo =
  if symbol.kind notin {symbolVar, symbolLet, symbolConst} or
      symbol.nameToken >= uint32(tokens.len):
    return
  let nameToken = int(symbol.nameToken)
  var first = nameToken - 1
  while first >= 0 and tokens[first].line == tokens[nameToken].line:
    if tokens[first].isKeyword(kwLet) or tokens[first].isKeyword(kwVar) or
        tokens[first].isKeyword(kwConst):
      break
    dec first
  if first < 0:
    return
  var past = nameToken + 1
  while past < tokens.len and tokens[past].line == tokens[nameToken].line:
    inc past
  let kind =
    case symbol.kind
    of symbolLet: declarationLet
    of symbolVar: declarationVar
    of symbolConst: declarationConst
    else: declarationLet
  let declaration = LexicalDeclaration(
    scope: ScopeId(1),
    kind: kind,
    nameToken: symbol.nameToken,
    firstToken: uint32(first),
    pastToken: uint32(past),
  )
  let split = splitDeclaration(tokens, declaration)
  if split.colon >= 0 or split.equals < 0:
    return
  let descriptor = declarationTypeDescriptor(tokens, declaration)
  let expected = types.descriptorTypeId(descriptor)
  if expected == InvalidTypeId or not descriptor.kind.isPrimitiveType:
    return
  result.kind = descriptor.kind
  result.state = typeStateResolved
  result.form = localTypeFormLiteral
  result.typeId = expected
  result.firstToken = uint32(split.equals + 1)
  result.pastToken = uint32(past)
