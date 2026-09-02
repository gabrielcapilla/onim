import std/[algorithm, strutils]

import ../syntax/imports
import ../syntax/lexer
import ./occurrences
import ./scopes
import ./symbols

type SourceIndex* = ref object
  contentHash*: uint64
  byteLength*: int
  tokenCount*: int
  parsed*: SourceImports
  symbols*: seq[SourceSymbol]
  scopes*: ScopeIndex
  occurrences*: OccurrenceIndex
  imports*: seq[string]
  exports*: seq[string]
  includes*: seq[string]

proc contentFingerprint*(source: string): uint64 =
  var fingerprint = 14695981039346656037'u64
  for character in source:
    fingerprint = (fingerprint xor uint64(ord(character))) * 1099511628211'u64
  fingerprint

proc canonicalReference(module: string): string =
  result = module.strip(chars = {'"', '\'', '`'})
  result = result.replace('\\', '/')
  var prefix = ""
  if result.len > 3 and result.startsWith("../"):
    prefix = "../"
    result = result[3 .. ^1]
  elif result.len > 2 and result.startsWith("./"):
    prefix = "./"
    result = result[2 .. ^1]
  result = result.replace('.', '/')
  while result.contains("//"):
    result = result.replace("//", "/")
  result = prefix & result

proc addUnique(values: var seq[string], value: string) =
  if value.len == 0:
    return
  for existing in values:
    if existing == value:
      return
  values.add value

proc collectExportReferences(tokens: seq[Token], start: int): seq[string] =
  var cursor = start + 1
  while cursor < tokens.len:
    if tokens[cursor].text == "except":
      break
    if tokens[cursor].text == ",":
      inc cursor
      continue
    if tokens[cursor].kind != tkIdentifier:
      break

    var reference = tokens[cursor].text
    inc cursor
    while cursor + 1 < tokens.len and
        (tokens[cursor].text == "/" or tokens[cursor].text == ".") and
        tokens[cursor + 1].kind == tkIdentifier
    :
      reference.add tokens[cursor].text
      reference.add tokens[cursor + 1].text
      inc cursor, 2
    addUnique(result, canonicalReference(reference))
    if cursor >= tokens.len or tokens[cursor].text != ",":
      break

proc indexSource*(source: string): SourceIndex =
  new(result)
  result.contentHash = contentFingerprint(source)
  result.byteLength = source.len
  result.parsed = parseSourceImports(source)
  result.tokenCount = result.parsed.tokens.len
  result.symbols = indexSymbols(source, result.parsed.tokens)
  result.scopes = indexScopes(result.parsed.tokens, result.symbols, result.byteLength)
  result.occurrences = indexOccurrences(result.parsed, result.symbols)

  for item in result.parsed.imports:
    addUnique(result.imports, canonicalReference(item.module))

  for tokenIndex, token in result.parsed.tokens:
    if token.text == "export":
      for reference in collectExportReferences(result.parsed.tokens, tokenIndex):
        addUnique(result.exports, reference)

  for tokenIndex, token in result.parsed.tokens:
    if token.text != "include" or tokenIndex + 1 >= result.parsed.tokens.len:
      continue
    var includeName = canonicalReference(result.parsed.tokens[tokenIndex + 1].text)
    if includeName.len == 0:
      continue
    if not includeName.endsWith(".nim"):
      includeName.add ".nim"
    addUnique(result.includes, includeName)

  result.imports.sort
  result.includes.sort
