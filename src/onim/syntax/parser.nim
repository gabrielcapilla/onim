import ./imports
import ./lexer

type
  SyntaxNodeId* = distinct uint32

  SyntaxNodeKind* = enum
    syntaxModule
    syntaxImport
    syntaxFromImport
    syntaxWhen
    syntaxBlock
    syntaxInclude
    syntaxExport
    syntaxDeclaration

  ParserUncertainty* = enum
    parserMalformed
    parserUnbalanced
    parserIncomplete
    parserUnsupportedStructure
    parserNestedDeclaration

  SyntaxNode* = object
    kind*: SyntaxNodeKind
    parent*: SyntaxNodeId
    firstToken*: uint32
    pastToken*: uint32
    uncertainty*: set[ParserUncertainty]

  PartialSyntaxTree* = object
    tokens*: TokenStore
    nodes*: seq[SyntaxNode]
    root*: SyntaxNodeId
    importNodes*: seq[SyntaxNodeId]
    declarationNodes*: seq[SyntaxNodeId]
    uncertainty*: set[ParserUncertainty]

const InvalidSyntaxNodeId* = SyntaxNodeId(0)

proc `==`*(left, right: SyntaxNodeId): bool {.borrow.}

proc nodeIndex(id: SyntaxNodeId): int {.inline.} =
  if uint32(id) == 0'u32:
    return -1
  int(uint32(id)) - 1

proc addNode(
    tree: var PartialSyntaxTree,
    kind: SyntaxNodeKind,
    firstToken, pastToken: int,
    uncertainty: set[ParserUncertainty],
): SyntaxNodeId =
  tree.nodes.add SyntaxNode(
    kind: kind,
    parent: InvalidSyntaxNodeId,
    firstToken: uint32(firstToken),
    pastToken: uint32(pastToken),
    uncertainty: uncertainty,
  )
  SyntaxNodeId(uint32(tree.nodes.len))

proc statementStart(tokens: TokenStore, index: int): bool {.inline.} =
  if index <= 0:
    return true
  let previous = tokens[index - 1]
  let current = tokens[index]
  if previous.line == current.line:
    return tokens.tokenTextEquals(previous, ";")
  if current.isModuleStatementStart:
    return current.column <= previous.column
  not tokens.tokenTextEquals(previous, ",") and not tokens.tokenTextEquals(
    previous, "/"
  ) and not tokens.tokenTextEquals(previous, ".") and
    not tokens.tokenTextEquals(previous, "\\")

proc blockEnd*[T](tokens: T, start: int): int =
  let baseColumn = tokens[start].column
  var index = start + 1
  while index < tokens.len:
    if tokens[index].line > tokens[start].line and tokens[index].column <= baseColumn:
      break
    inc index
  index

proc declarationStart(token: Token): bool {.inline.} =
  token.hasKeywordRole(roleDeclaration) and not token.hasKeywordRole(roleForBinding)

proc hasToken(tokens: TokenStore, first, past: int, wanted: string): bool {.inline.} =
  for index in first ..< past:
    if tokens.tokenTextEquals(tokens[index], wanted):
      return true
  false

proc validNodeRange(tree: PartialSyntaxTree, node: SyntaxNode): bool {.inline.} =
  let first = int(node.firstToken)
  let past = int(node.pastToken)
  first >= 0 and past <= tree.tokens.len and first < past

proc isContainer(kind: SyntaxNodeKind): bool {.inline.} =
  kind in {syntaxWhen, syntaxBlock, syntaxDeclaration}

proc unnamedBlockHeader(tokens: TokenStore, index: int): bool {.inline.} =
  index + 1 < tokens.len and tokens[index + 1].line == tokens[index].line and
    tokens.tokenTextEquals(tokens[index + 1], ":")

proc assignParents(tree: var PartialSyntaxTree) =
  if tree.nodes.len < 2:
    return
  var containers: seq[int] = @[]
  for childIndex in 1 ..< tree.nodes.len:
    let child = tree.nodes[childIndex]
    while containers.len > 0 and tree.nodes[containers[^1]].pastToken <= child.firstToken:
      containers.setLen(containers.len - 1)
    if containers.len > 0:
      let parentIndex = containers[^1]
      if child.pastToken <= tree.nodes[parentIndex].pastToken:
        tree.nodes[childIndex].parent = SyntaxNodeId(uint32(parentIndex + 1))
    if child.kind.isContainer:
      containers.add childIndex

proc applyLexicalUncertainty(tree: var PartialSyntaxTree) =
  for issue in lexicalIssues(tree.tokens):
    case issue.kind
    of lexicalMalformedIdentifier, lexicalUnclosedString:
      tree.uncertainty.incl parserMalformed
    of lexicalUnexpectedDelimiter, lexicalUnclosedDelimiter:
      tree.uncertainty.incl parserUnbalanced

proc mapStatementUncertainty(
    uncertainty: set[StatementUncertainty]
): set[ParserUncertainty] =
  for reason in uncertainty:
    case reason
    of statementIncomplete:
      result.incl parserIncomplete
    of statementUnbalanced:
      result.incl parserUnbalanced
    of statementUnsupported:
      result.incl parserUnsupportedStructure

proc parsePartialSyntax*(tokens: TokenStore, source = ""): PartialSyntaxTree =
  result.tokens = tokens
  result.root = result.addNode(syntaxModule, 0, result.tokens.len, {})
  result.applyLexicalUncertainty()

  var index = 0
  while index < result.tokens.len:
    let token = result.tokens[index]
    if not token.isKeyword(kwImport) and not token.isKeyword(kwFrom) and
        not token.isKeyword(kwWhen) and not token.isKeyword(kwInclude) and
        not token.isKeyword(kwExport) and not token.isKeyword(kwBlock) and
        not token.declarationStart:
      inc index
      continue
    if not statementStart(result.tokens, index):
      inc index
      continue

    var kind = syntaxModule
    var past = index + 1
    var nodeUncertainty: set[ParserUncertainty] = {}
    if token.isKeyword(kwImport):
      kind = syntaxImport
      let statement = statementRange(result.tokens, index)
      past = statement.past
      nodeUncertainty = mapStatementUncertainty(statement.uncertainty)
      if statementHasMissingOperand(result.tokens, index, past):
        nodeUncertainty.incl parserIncomplete
      elif past <= index + 1 or (
        index + 1 < past and result.tokens[index + 1].kind != tkIdentifier and
        not result.tokens.tokenTextEquals(result.tokens[index + 1], "\"")
      ):
        nodeUncertainty.incl parserUnsupportedStructure
    elif token.isKeyword(kwFrom):
      kind = syntaxFromImport
      let statement = statementRange(result.tokens, index)
      past = statement.past
      nodeUncertainty = mapStatementUncertainty(statement.uncertainty)
      if not result.tokens.fromStatementComplete(index, past):
        nodeUncertainty.incl parserIncomplete
    elif token.isKeyword(kwWhen):
      kind = syntaxWhen
      let statement = blockEnd(result.tokens, index)
      past = statement
      if not hasToken(result.tokens, index + 1, min(past, result.tokens.len), ":"):
        nodeUncertainty.incl parserUnsupportedStructure
    elif token.isKeyword(kwBlock):
      if unnamedBlockHeader(result.tokens, index):
        kind = syntaxBlock
        past = blockEnd(result.tokens, index)
      else:
        kind = syntaxBlock
        past = blockEnd(result.tokens, index)
        nodeUncertainty.incl parserUnsupportedStructure
    elif token.isKeyword(kwInclude):
      kind = syntaxInclude
      let parsed = parseIncludeReferences(result.tokens, source, index)
      past = parsed.next
      nodeUncertainty = mapStatementUncertainty(parsed.uncertainty)
    elif token.isKeyword(kwExport):
      kind = syntaxExport
      let parsed = parseExportNames(result.tokens, index)
      past = parsed.next
      nodeUncertainty = mapStatementUncertainty(parsed.uncertainty)
    elif token.declarationStart:
      kind = syntaxDeclaration
      past = blockEnd(result.tokens, index)
      if token.column > 0:
        nodeUncertainty.incl parserNestedDeclaration
      if token.hasKeywordRole(roleRoutine) and
          not hasToken(result.tokens, index + 1, min(past, result.tokens.len), "="):
        nodeUncertainty.incl parserUnsupportedStructure

    if past <= index or past > result.tokens.len:
      nodeUncertainty.incl parserUnsupportedStructure
      past = min(result.tokens.len, index + 1)
    for reason in nodeUncertainty:
      result.uncertainty.incl reason
    let node = result.addNode(kind, index, past, nodeUncertainty)
    case kind
    of syntaxImport, syntaxFromImport:
      result.importNodes.add node
    of syntaxDeclaration:
      result.declarationNodes.add node
    else:
      discard
    if kind in {syntaxImport, syntaxFromImport, syntaxInclude, syntaxExport}:
      index = max(index + 1, past)
    else:
      inc index

  result.assignParents()

proc parsePartialSyntax*(source: string): PartialSyntaxTree =
  parsePartialSyntax(lex(source), source)

proc isComplete*(tree: PartialSyntaxTree): bool {.inline.} =
  tree.uncertainty == {}

proc validateSyntaxTree*(tree: PartialSyntaxTree): bool =
  if uint32(tree.root) != 1'u32 or tree.nodes.len == 0:
    return false
  let root = tree.nodes[0]
  if root.kind != syntaxModule or uint32(root.parent) != 0'u32 or root.firstToken != 0 or
      root.pastToken != uint32(tree.tokens.len):
    return false
  for index, node in tree.nodes:
    if index > 0 and not tree.validNodeRange(node):
      return false
    if uint32(node.parent) != 0'u32:
      let parentIndex = nodeIndex(node.parent)
      if parentIndex <= 0 or parentIndex >= tree.nodes.len or parentIndex == index:
        return false
      let parent = tree.nodes[parentIndex]
      if parent.firstToken > node.firstToken or node.pastToken > parent.pastToken:
        return false
  for nodeId in tree.importNodes:
    let index = nodeIndex(nodeId)
    if index <= 0 or index >= tree.nodes.len or
        tree.nodes[index].kind notin {syntaxImport, syntaxFromImport}:
      return false
  for nodeId in tree.declarationNodes:
    let index = nodeIndex(nodeId)
    if index <= 0 or index >= tree.nodes.len or
        tree.nodes[index].kind != syntaxDeclaration:
      return false
  true

proc sameImportNode(
    tree: PartialSyntaxTree, node: SyntaxNode, item: ImportInfo
): bool {.inline.} =
  let first = int(node.firstToken)
  let past = int(node.pastToken)
  if first < 0 or past <= first or past > tree.tokens.len:
    return false
  let formMatches =
    (node.kind == syntaxImport and item.form == importModule) or
    (node.kind == syntaxFromImport and item.form == fromModule)
  formMatches and tree.tokens[first].startOffset == item.startOffset and
    tree.tokens[past - 1].endOffset == item.endOffset

proc overlapsUncertainImportNode(tree: PartialSyntaxTree, item: ImportInfo): bool =
  for nodeId in tree.importNodes:
    let node = tree.nodes[nodeIndex(nodeId)]
    if node.uncertainty == {}:
      continue
    let first = int(node.firstToken)
    let past = int(node.pastToken)
    if first < 0 or past <= first or past > tree.tokens.len:
      continue
    let nodeStart = tree.tokens[first].startOffset
    let nodeEnd = tree.tokens[past - 1].endOffset
    if item.startOffset < nodeEnd and nodeStart < item.endOffset:
      return true

proc hasSameImportShape(imports: SourceImports, itemIndex: int): bool {.inline.} =
  let item = imports.imports[itemIndex]
  if item.synthetic:
    return true
  for previous in 0 ..< itemIndex:
    let candidate = imports.imports[previous]
    if not candidate.synthetic and candidate.form == item.form and
        candidate.startOffset == item.startOffset and
        candidate.endOffset == item.endOffset:
      return true
  false

proc importsMatch*(tree: PartialSyntaxTree, current: SourceImports): bool =
  if not tree.validateSyntaxTree:
    return false
  var distinctImports = 0
  for index, item in current.imports:
    if tree.overlapsUncertainImportNode(item):
      return false
    if not hasSameImportShape(current, index):
      inc distinctImports
      var found = false
      for nodeId in tree.importNodes:
        if tree.sameImportNode(tree.nodes[nodeIndex(nodeId)], item):
          found = true
          break
      if not found:
        return false
  var certainImportNodes = 0
  for nodeId in tree.importNodes:
    if tree.nodes[nodeIndex(nodeId)].uncertainty == {}:
      inc certainImportNodes
  if distinctImports != certainImportNodes:
    return false
  for nodeId in tree.importNodes:
    let node = tree.nodes[nodeIndex(nodeId)]
    if node.uncertainty != {}:
      continue
    var found = false
    for item in current.imports:
      if tree.sameImportNode(node, item):
        found = true
        break
    if not found:
      return false
  true
