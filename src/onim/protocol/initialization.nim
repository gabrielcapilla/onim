import std/json

import ../features/semantic_tokens
import ./uris
import ./validation

proc boolOption*(params: JsonNode, key: string, fallback: bool): bool =
  let options = valueOrEmpty(params, "initializationOptions")
  if options.kind == JObject and options.hasKey(key) and options[key].kind == JBool:
    options[key].getBool
  else:
    fallback

proc clientSupportsCompletionItemBoolean(params: JsonNode, key: string): bool =
  let capabilities = valueOrEmpty(params, "capabilities")
  let textDocument = valueOrEmpty(capabilities, "textDocument")
  let completion = valueOrEmpty(textDocument, "completion")
  let completionItem = valueOrEmpty(completion, "completionItem")
  completionItem.hasKey(key) and completionItem[key].kind == JBool and
    completionItem[key].getBool

proc clientSupportsInsertReplace*(params: JsonNode): bool =
  clientSupportsCompletionItemBoolean(params, "insertReplaceSupport")

proc clientSupportsSnippets*(params: JsonNode): bool =
  clientSupportsCompletionItemBoolean(params, "snippetSupport")

proc initializeRoot*(params: JsonNode): string =
  if params != nil and params.kind == JObject:
    if params.hasKey("rootUri") and params["rootUri"].kind == JString:
      let uriText = params["rootUri"].getStr
      if uriText.len > 0:
        return uriToPath(uriText)
    if params.hasKey("rootPath") and params["rootPath"].kind == JString:
      let rootPath = params["rootPath"].getStr
      if rootPath.len > 0:
        return rootPath
    if params.hasKey("workspaceFolders") and params["workspaceFolders"].kind == JArray:
      for folder in params["workspaceFolders"].items:
        if folder.kind == JObject and folder.hasKey("uri") and
            folder["uri"].kind == JString:
          return uriToPath(folder["uri"].getStr)
  ""

proc initializeResult*(): JsonNode =
  var provider = newJObject()
  provider["codeActionKinds"] = %*["source.organizeImports", "quickfix"]
  provider["resolveProvider"] = %false
  var sync = newJObject()
  sync["openClose"] = %true
  sync["change"] = %2
  sync["save"] = %*{"includeText": true}
  var capabilities = newJObject()
  capabilities["textDocumentSync"] = sync
  capabilities["codeActionProvider"] = provider
  capabilities["definitionProvider"] = %true
  capabilities["typeDefinitionProvider"] = %true
  capabilities["implementationProvider"] = %true
  capabilities["callHierarchyProvider"] = %true
  capabilities["completionProvider"] =
    %*{"resolveProvider": false, "triggerCharacters": [".", "{", ":", " "]}
  capabilities["hoverProvider"] = %true
  capabilities["renameProvider"] = %*{"prepareProvider": true}
  capabilities["referencesProvider"] = %true
  capabilities["documentSymbolProvider"] = %true
  capabilities["documentHighlightProvider"] = %true
  capabilities["foldingRangeProvider"] = %true
  capabilities["selectionRangeProvider"] = %true
  capabilities["documentLinkProvider"] = %*{"resolveProvider": false}
  capabilities["inlayHintProvider"] = %true
  capabilities["signatureHelpProvider"] =
    %*{"triggerCharacters": ["(", ","], "retriggerCharacters": [","]}
  var semanticTokenTypes = newJArray()
  for kind in SemanticTokenKind:
    semanticTokenTypes.add %semanticTokenTypeNames[kind]
  capabilities["semanticTokensProvider"] = %*{
    "legend": {"tokenTypes": semanticTokenTypes, "tokenModifiers": []},
    "full": true,
    "range": true,
  }
  capabilities["workspaceSymbolProvider"] = %true
  capabilities["positionEncoding"] = %"utf-16"
  result = newJObject()
  result["capabilities"] = capabilities
  result["serverInfo"] = %*{"name": "onim", "version": "0.1.0"}
