import std/json

import ../index/symbols

proc sourceSymbolKind*(kind: string, kindKnown: var bool): SourceSymbolKind =
  kindKnown = true
  case kind
  of "skProc", "proc":
    symbolProc
  of "skFunc", "func":
    symbolFunc
  of "skIterator", "iterator":
    symbolIterator
  of "skMethod", "method":
    symbolMethod
  of "skMacro", "macro":
    symbolMacro
  of "skTemplate", "template":
    symbolTemplate
  of "skConverter", "converter":
    symbolConverter
  of "skType", "type":
    symbolType
  of "skVar", "var":
    symbolVar
  of "skLet", "let":
    symbolLet
  of "skConst", "const":
    symbolConst
  else:
    kindKnown = false
    symbolProc

proc intField*(node: JsonNode, name: string, fallback: int): int =
  if node != nil and node.kind == JObject and node.hasKey(name) and
      node[name].kind == JInt:
    return node[name].getInt
  fallback

proc stringField*(node: JsonNode, name: string): string =
  if node != nil and node.kind == JObject and node.hasKey(name) and
      node[name].kind == JString:
    return node[name].getStr
  ""
