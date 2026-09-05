import ./imports
import ./lexer

type
  SyntaxNodeId* = distinct uint32

  SyntaxNodeKind* = enum
    syntaxModule
    syntaxImport
    syntaxFromImport
    syntaxWhen
    syntaxInclude
    syntaxExport
    syntaxDeclaration

  ParserUncertainty* = enum
    parserMalformed
    parserUnbalanced
    parserUnsupportedStructure
    parserNestedDeclaration

  SyntaxNode* = object
    kind*: SyntaxNodeKind
    parent*: SyntaxNodeId
    firstToken*: uint32
    pastToken*: uint32

  PartialSyntaxTree* = object
    tokens*: TokenStore
    nodes*: seq[SyntaxNode]
    root*: SyntaxNodeId
    importNodes*: seq[SyntaxNodeId]
    declarationNodes*: seq[SyntaxNodeId]
    uncertainty*: set[ParserUncertainty]

const InvalidSyntaxNodeId* = SyntaxNodeId(0)

proc nodeIndex(id: SyntaxNodeId): int {.inline.} =
  if uint32(id) == 0'u32:
    return -1
  int(uint32(id)) - 1

proc addNode(
    tree: var PartialSyntaxTree, kind: SyntaxNodeKind, firstToken, pastToken: int
): SyntaxNodeId =
  tree.nodes.add SyntaxNode(
    kind: kind,
    parent: InvalidSyntaxNodeId,
    firstToken: uint32(firstToken),
    pastToken: uint32(pastToken),
  )
  SyntaxNodeId(uint32(tree.nodes.len))

proc statementStart[T](tokens: T, index: int): bool {.inline.} =
  if index <= 0:
    return true
  let previous = tokens[index - 1]
  let current = tokens[index]
  if previous.line == current.line:
    return previous.text == ";"
  previous.text != "," and previous.text != "/" and previous.text != "." and
    previous.text != "\\"

proc blockEnd[T](tokens: T, start: int): int =
  let baseColumn = tokens[start].column
  var index = start + 1
  while index < tokens.len:
    if tokens[index].line > tokens[start].line and tokens[index].column <= baseColumn:
      break
    inc index
  index

proc declarationStart(token: Token): bool {.inline.} =
  token.hasKeywordRole(roleDeclaration) and not token.hasKeywordRole(roleForBinding)

proc hasToken[T](tokens: T, first, past: int, wanted: string): bool {.inline.} =
  for index in first ..< past:
    if tokens[index].text == wanted:
      return true
  false

proc validNodeRange(tree: PartialSyntaxTree, node: SyntaxNode): bool {.inline.} =
  let first = int(node.firstToken)
  let past = int(node.pastToken)
  first >= 0 and past <= tree.tokens.len and first < past

proc isContainer(kind: SyntaxNodeKind): bool {.inline.} =
  kind in {syntaxWhen, syntaxDeclaration}

proc assignParents(tree: var PartialSyntaxTree) =
  if tree.nodes.len < 2:
    return
  for childIndex in 1 ..< tree.nodes.len:
    let child = tree.nodes[childIndex]
    var parentIndex = -1
    var parentWidth = high(uint32)
    for candidateIndex in 1 ..< tree.nodes.len:
      if candidateIndex == childIndex:
        continue
      let candidate = tree.nodes[candidateIndex]
      if not candidate.kind.isContainer:
        continue
      if candidate.firstToken <= child.firstToken and
          child.pastToken <= candidate.pastToken:
        let width = candidate.pastToken - candidate.firstToken
        if width < parentWidth:
          parentWidth = width
          parentIndex = candidateIndex
    if parentIndex >= 0:
      tree.nodes[childIndex].parent = SyntaxNodeId(uint32(parentIndex + 1))

proc applyLexicalUncertainty(tree: var PartialSyntaxTree) =
  for issue in lexicalIssues(tree.tokens):
    case issue.kind
    of lexicalMalformedIdentifier, lexicalUnclosedString:
      tree.uncertainty.incl parserMalformed
    of lexicalUnexpectedDelimiter, lexicalUnclosedDelimiter:
      tree.uncertainty.incl parserUnbalanced

proc parsePartialSyntax*(source: string): PartialSyntaxTree =
  let lexed = lex(source)
  result.tokens = initTokenStore(lexed)
  result.root = result.addNode(syntaxModule, 0, result.tokens.len)
  result.applyLexicalUncertainty()

  var index = 0
  while index < result.tokens.len:
    let token = result.tokens[index]
    if not token.isKeyword(kwImport) and not token.isKeyword(kwFrom) and
        not token.isKeyword(kwWhen) and not token.isKeyword(kwInclude) and
        not token.isKeyword(kwExport) and not token.declarationStart:
      inc index
      continue
    if not statementStart(result.tokens, index):
      inc index
      continue

    var kind = syntaxModule
    var past = index + 1
    if token.isKeyword(kwImport):
      kind = syntaxImport
      past = statementEnd(result.tokens, index)
      if past <= index + 1 or (
        index + 1 < past and result.tokens[index + 1].kind != tkIdentifier and
        result.tokens[index + 1].text != "\""
      ):
        result.uncertainty.incl parserUnsupportedStructure
    elif token.isKeyword(kwFrom):
      kind = syntaxFromImport
      past = statementEnd(result.tokens, index)
      if not hasToken(result.tokens, index + 1, past, "import"):
        result.uncertainty.incl parserUnsupportedStructure
    elif token.isKeyword(kwWhen):
      kind = syntaxWhen
      past = blockEnd(result.tokens, index)
      if not hasToken(result.tokens, index + 1, min(past, result.tokens.len), ":"):
        result.uncertainty.incl parserUnsupportedStructure
    elif token.isKeyword(kwInclude):
      kind = syntaxInclude
      past = statementEnd(result.tokens, index)
    elif token.isKeyword(kwExport):
      kind = syntaxExport
      past = statementEnd(result.tokens, index)
    elif token.declarationStart:
      kind = syntaxDeclaration
      past = blockEnd(result.tokens, index)
      if token.column > 0:
        result.uncertainty.incl parserNestedDeclaration
      if token.hasKeywordRole(roleRoutine) and
          not hasToken(result.tokens, index + 1, min(past, result.tokens.len), "="):
        result.uncertainty.incl parserUnsupportedStructure

    if past <= index or past > result.tokens.len:
      result.uncertainty.incl parserUnsupportedStructure
      past = min(result.tokens.len, index + 1)
    let node = result.addNode(kind, index, past)
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
    if not hasSameImportShape(current, index):
      inc distinctImports
      var found = false
      for nodeId in tree.importNodes:
        if tree.sameImportNode(tree.nodes[nodeIndex(nodeId)], item):
          found = true
          break
      if not found:
        return false
  if distinctImports != tree.importNodes.len:
    return false
  for nodeId in tree.importNodes:
    let node = tree.nodes[nodeIndex(nodeId)]
    var found = false
    for item in current.imports:
      if tree.sameImportNode(node, item):
        found = true
        break
    if not found:
      return false
  true
