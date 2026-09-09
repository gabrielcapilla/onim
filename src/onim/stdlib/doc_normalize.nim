import std/strutils

proc htmlTagName(tag: string): string {.inline.} =
  var first = 0
  if first < tag.len and tag[first] == '/':
    inc first
  while first < tag.len and tag[first] in {' ', '\t', '\r', '\n'}:
    inc first
  var past = first
  while past < tag.len and tag[past] notin {' ', '\t', '\r', '\n', '/'}:
    inc past
  if first < past:
    result = tag[first ..< past].toLowerAscii

proc appendDocumentationBreak(value: var string) {.inline.} =
  if value.len > 0 and value[^1] != '\n':
    value.add '\n'

proc normalizeDocumentation*(value: string): string =
  if value.len == 0:
    return
  var rendered = newStringOfCap(value.len)
  var cursor = 0
  while cursor < value.len:
    if value[cursor] == '<':
      let close = value.find('>', cursor + 1)
      if close >= 0:
        let tag = value[cursor + 1 ..< close]
        let name = htmlTagName(tag)
        let closing = tag.len > 0 and tag[0] == '/'
        case name
        of "br", "hr", "p", "div", "section", "article", "h1", "h2", "h3", "h4", "h5",
            "h6", "ul", "ol":
          rendered.appendDocumentationBreak()
        of "li":
          if closing:
            rendered.appendDocumentationBreak()
          else:
            rendered.appendDocumentationBreak()
            rendered.add "- "
        of "pre":
          if closing:
            rendered.appendDocumentationBreak()
            rendered.add "```"
          else:
            rendered.appendDocumentationBreak()
            rendered.add "```nim\n"
        of "tt", "code":
          rendered.add '`'
        of "em", "i":
          rendered.add '*'
        of "strong", "b":
          rendered.add "**"
        else:
          discard
        cursor = close + 1
        continue
    if value[cursor] == '&':
      let finish = value.find(';', cursor + 1)
      if finish >= 0 and finish - cursor <= 16:
        let entity = value[cursor + 1 ..< finish]
        case entity
        of "amp":
          rendered.add '&'
        of "quot":
          rendered.add '"'
        of "apos", "#x27", "#X27":
          rendered.add '\''
        of "lt":
          rendered.add '<'
        of "gt":
          rendered.add '>'
        of "nbsp":
          rendered.add ' '
        else:
          rendered.add '&'
          rendered.add entity
          rendered.add ';'
        cursor = finish + 1
        continue
    rendered.add value[cursor]
    inc cursor
  var lines: seq[string] = @[]
  for line in rendered.replace('\r', '\n').splitLines:
    let trimmed = line.strip
    if trimmed.len == 0 and (lines.len == 0 or lines[^1].len == 0):
      continue
    lines.add trimmed
  result = lines.join("\n").strip
  while result.contains("\n\n\n"):
    result = result.replace("\n\n\n", "\n\n")
