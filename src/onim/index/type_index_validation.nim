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
import ./type_object_queries
import ./type_queries
import ./type_routine_returns

proc validateTypeIndex*(
    index: TypeIndex,
    tokens: TokenStore,
    symbols: openArray[SourceSymbol],
    scopes: ScopeIndex,
): bool =
  if index.localTypeIds.len != scopes.declarations.len or
      index.routineReturnTypeIds.len != symbols.len:
    return false
  for recordIndex, record in index.records:
    if record.firstArgument > record.pastArgument or
        record.pastArgument > uint32(index.genericArgumentTypeIds.len) or
        record.kind != typeGenericInstance and
        record.firstArgument != record.pastArgument:
      return false
    case record.kind
    of typeUnknown:
      return false
    of typeNamed:
      if record.nameToken == InvalidTypeToken or record.baseType.valid or
          record.extent != 0'u32 or record.nameToken >= uint32(tokens.len) or
          not validNameToken(tokens, int(record.nameToken)):
        return false
    of typeSeq:
      if record.nameToken != InvalidTypeToken or not record.baseType.valid or
          record.extent != 0'u32 or uint32(record.baseType) > uint32(recordIndex):
        return false
    of typeRef:
      if record.nameToken != InvalidTypeToken or not record.baseType.valid or
          record.extent != 0'u32 or uint32(record.baseType) > uint32(recordIndex) or
          index.typeKind(record.baseType) != typeNamed:
        return false
    of typeArray:
      if record.nameToken != InvalidTypeToken or not record.baseType.valid or
          uint32(record.baseType) > uint32(recordIndex) or (
        not index.typeKind(record.baseType).isPrimitiveType and
        index.typeKind(record.baseType) != typeNamed
      ):
        return false
    of typeGenericInstance:
      if record.nameToken == InvalidTypeToken or not record.baseType.valid or
          uint32(record.baseType) > uint32(recordIndex) or record.extent != 0'u32 or
          record.firstArgument == record.pastArgument or
          record.baseType != index.genericArgumentTypeIds[int(record.firstArgument)] or
          record.nameToken >= uint32(tokens.len) or
          not validNameToken(tokens, int(record.nameToken)) or
          not (
            index.typeKind(record.baseType).isPrimitiveType or
            index.typeKind(record.baseType) == typeNamed
          ):
        return false
      for argumentIndex in record.firstArgument ..< record.pastArgument:
        let argument = index.genericArgumentTypeIds[int(argumentIndex)]
        let argumentKind = index.typeKind(argument)
        if not argument.valid or uint32(argument) > uint32(recordIndex) or
            not argumentKind.isPrimitiveType and argumentKind != typeNamed:
          return false
    else:
      if record.nameToken != InvalidTypeToken or record.baseType.valid or
          record.extent != 0'u32:
        return false
    for previous in 0 ..< recordIndex:
      if index.records[previous].kind == record.kind and
          index.records[previous].nameToken == record.nameToken and
          index.records[previous].baseType == record.baseType and
          index.records[previous].extent == record.extent and
          index.sameGenericRecordArguments(index.records[previous], record):
        return false
  var previousObject = high(uint32)
  for objectType in index.objects:
    if objectType.declarationToken >= uint32(tokens.len) or (
      previousObject != high(uint32) and objectType.declarationToken <= previousObject
    ) or objectType.firstField > objectType.pastField or
        objectType.pastField > uint32(index.fields.len) or
        objectType.firstGenericParameter > objectType.pastGenericParameter or
        objectType.pastGenericParameter > uint32(index.genericParameterTokens.len):
      return false
    previousObject = objectType.declarationToken
    var symbolMatches = 0
    for symbol in symbols:
      if symbol.kind == symbolType and symbol.nameToken == objectType.declarationToken:
        inc symbolMatches
    if symbolMatches != 1:
      return false
    let limit = typeDeclarationEnd(tokens, int(objectType.declarationToken))
    if limit < 0:
      return false
    if objectType.pastGenericParameter > objectType.firstGenericParameter:
      for parameterIndex in objectType.firstGenericParameter ..<
          objectType.pastGenericParameter:
        let parameterToken = index.genericParameterTokens[int(parameterIndex)]
        if parameterToken <= objectType.declarationToken or
            parameterToken >= uint32(limit) or
            not validNameToken(tokens, int(parameterToken)):
          return false
        for previous in objectType.firstGenericParameter ..< parameterIndex:
          if sameIdentifier(
            tokens.tokenText(tokens[int(index.genericParameterTokens[int(previous)])]),
            tokens.tokenText(tokens[int(parameterToken)]),
          ):
            return false
    if objectType.pastField > objectType.firstField:
      for fieldIndex in objectType.firstField ..< objectType.pastField:
        let fieldToken = index.fields[int(fieldIndex)].nameToken
        if fieldToken <= objectType.declarationToken or fieldToken >= uint32(limit) or
            not validNameToken(tokens, int(fieldToken)):
          return false
        for previous in objectType.firstField ..< fieldIndex:
          if sameIdentifier(
            tokens.tokenText(tokens[int(index.fields[int(previous)].nameToken)]),
            tokens.tokenText(tokens[int(fieldToken)]),
          ):
            return false
  var previousLocalTuple = high(uint32)
  for objectType in index.localTupleObjects:
    if objectType.declarationToken >= uint32(tokens.len) or (
      previousLocalTuple != high(uint32) and
      objectType.declarationToken <= previousLocalTuple
    ) or objectType.firstField > objectType.pastField or
        objectType.pastField > uint32(index.localTupleFields.len):
      return false
    let declarationOrdinal = scopes.declarationOrdinalAt(objectType.declarationToken)
    if declarationOrdinal < 0 or declarationOrdinal >= scopes.declarations.len:
      return false
    let declaration = scopes.declarations[declarationOrdinal]
    let descriptor = declarationTypeDescriptor(tokens, declaration)
    if not (
      descriptor.kind == typeNamed and descriptor.nameToken == declaration.nameToken
    ) and
        not (
          descriptor.kind == typeSeq and descriptor.baseKind == typeNamed and
          descriptor.baseNameToken == declaration.nameToken
        ):
      return false
    for fieldIndex in objectType.firstField ..< objectType.pastField:
      let fieldToken = index.localTupleFields[int(fieldIndex)].nameToken
      if fieldToken <= objectType.declarationToken or fieldToken >= declaration.pastToken or
          not validNameToken(tokens, int(fieldToken)):
        return false
      for previous in objectType.firstField ..< fieldIndex:
        if sameIdentifier(
          tokens.tokenText(tokens[int(index.localTupleFields[int(previous)].nameToken)]),
          tokens.tokenText(tokens[int(fieldToken)]),
        ):
          return false
    previousLocalTuple = objectType.declarationToken
  for declarationIndex, typeId in index.localTypeIds:
    if not typeId.valid:
      continue
    let declaration = scopes.declarations[declarationIndex]
    let descriptor = declarationTypeDescriptor(tokens, declaration)
    if index.descriptorTypeId(descriptor) != typeId:
      return false
    let typeToken =
      case descriptor.kind
      of typeNamed, typeGenericInstance: descriptor.nameToken
      of typeRef: descriptor.baseNameToken
      else: InvalidTypeToken
    if descriptor.kind notin {typeNamed, typeRef, typeGenericInstance}:
      continue
    if descriptor.kind == typeNamed and descriptor.nameToken == declaration.nameToken and
        index.localTupleObjectOrdinal(declaration.nameToken) < 0:
      return false
    if typeToken < declaration.firstToken or typeToken >= declaration.pastToken or
        not validNameToken(tokens, int(typeToken)):
      return false
  for symbolIndex, typeId in index.routineReturnTypeIds:
    if not typeId.valid:
      continue
    if symbolIndex >= symbols.len:
      return false
    let descriptor = routineReturnSpan(tokens, symbols[symbolIndex]).descriptor
    if index.descriptorTypeId(descriptor) != typeId:
      return false
  var previousTypeId = InvalidTypeId
  var previousSymbol = 0'u32
  var previousParameter = 0'u32
  for candidateIndex, candidate in index.ufcsProcedures:
    if not candidate.typeId.valid or index.typeKind(candidate.typeId) == typeUnknown or
        candidate.symbolOrdinal >= uint32(symbols.len) or
        candidate.parameterOrdinal >= uint32(scopes.declarations.len):
      return false
    let symbol = symbols[int(candidate.symbolOrdinal)]
    if symbol.kind notin {symbolProc, symbolFunc, symbolMethod}:
      return false
    let parameter = scopes.declarations[int(candidate.parameterOrdinal)]
    if parameter.kind != declarationParameter or
        index.localTypeIds[int(candidate.parameterOrdinal)] != candidate.typeId:
      return false
    let scopeOrdinal = int(uint32(parameter.scope)) - 1
    if scopeOrdinal <= 0 or scopeOrdinal >= scopes.scopes.len or
        scopes.scopes[scopeOrdinal].kind != scopeRoutine or
        scopes.scopes[scopeOrdinal].ownerSymbol != candidate.symbolOrdinal:
      return false
    var firstParameter = -1
    for declarationIndex, declaration in scopes.declarations:
      if declaration.scope == parameter.scope and
          declaration.kind == declarationParameter:
        if firstParameter < 0 or
            declaration.nameToken < scopes.declarations[firstParameter].nameToken:
          firstParameter = declarationIndex
    if firstParameter != int(candidate.parameterOrdinal):
      return false
    if candidateIndex > 0:
      if uint32(candidate.typeId) < uint32(previousTypeId) or
          candidate.typeId == previousTypeId and candidate.symbolOrdinal < previousSymbol or
          candidate.typeId == previousTypeId and
          candidate.symbolOrdinal == previousSymbol and
          candidate.parameterOrdinal <= previousParameter:
        return false
    previousTypeId = candidate.typeId
    previousSymbol = candidate.symbolOrdinal
    previousParameter = candidate.parameterOrdinal
  true
