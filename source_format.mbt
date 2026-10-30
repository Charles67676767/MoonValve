///|
priv struct FormatToken {
  start : Int32
  end : Int32
  kind : String
}

///|
fn format_tokens(
  chars : Array[Char],
  verbatim : Map[Int32, Int32],
  kv3 : Bool,
) -> Array[FormatToken] {
  let result : Array[FormatToken] = []
  let mut i = 0
  while i < chars.length() {
    if is_space(chars[i]) {
      i += 1
      continue
    }
    let start = i
    let mut kind = "literal"
    if verbatim.get(i) is Some(end) {
      i = end
    } else if chars[i] == '\uFEFF' {
      kind = "bom"
      i += 1
    } else if chars[i] == '/' && chars.get(i + 1) == Some('/') {
      kind = "line-comment"
      i += 2
      while i < chars.length() {
        if chars[i] == '\r' || chars[i] == '\n' {
          if !kv3 || i == start || chars[i - 1] != '\\' {
            break
          }
          if chars[i] == '\r' && chars.get(i + 1) == Some('\n') {
            i += 1
          }
        }
        i += 1
      }
    } else if kv3 && chars[i] == '/' && chars.get(i + 1) == Some('*') {
      kind = "comment"
      i += 2
      while i + 1 < chars.length() && !(chars[i] == '*' && chars[i + 1] == '/') {
        i += 1
      }
      i = (i + 2).min(chars.length())
    } else if kv3 && chars[i] == '<' {
      kind = "header"
      while i + 2 < chars.length() &&
            !(chars[i] == '-' && chars[i + 1] == '-' && chars[i + 2] == '>') {
        i += 1
      }
      i = (i + 3).min(chars.length())
    } else if !kv3 && chars[i] == '[' {
      kind = "condition"
      i += 1
      while i < chars.length() && chars[i] != ']' {
        i += 1
      }
      i = (i + 1).min(chars.length())
    } else {
      kind = chars[i].to_string()
      i += 1
    }
    result.push({ start, end: i, kind, })
  }
  result
}

///|
fn format_layout(
  text : String,
  verbatim : Map[Int32, Int32],
  breaks : Map[Int32, Bool],
  kv3 : Bool,
) -> String {
  let chars = text.to_array()
  let tokens = format_tokens(chars, verbatim, kv3)
  let newline = if text.contains("\r\n") {
    "\r\n"
  } else if text.contains("\r") {
    "\r"
  } else {
    "\n"
  }
  let out = StringBuilder()
  let mut depth = 0
  let mut previous = ""
  let mut end = 0
  for token in tokens {
    if token.kind == "}" || token.kind == "]" {
      depth = (depth - 1).max(0)
    }
    let gap = String::from_array(chars[end:token.start].to_owned())
    if end != 0 && previous != "bom" {
      let hard_break = breaks.contains(token.start) ||
        previous == "line-comment" ||
        previous == "header"
      if hard_break || gap.contains("\n") || gap.contains("\r") {
        out.write_string(newline)
        // Retain one empty separator line without growing on repeated formatting.
        if gap
          .replace_all(old="\r\n", new="\n")
          .replace_all(old="\r", new="\n")
          .to_array()
          .filter(c => c == '\n')
          .length() >=
          2 {
          out.write_string(newline)
        }
        for _ in 0..<depth {
          out.write_string("  ")
        }
      } else if token.kind != "," && token.kind != ":" && previous != ":" {
        out.write_string(" ")
      }
    }
    out.write_string(
      String::from_array(chars[token.start:token.end].to_owned()),
    )
    if token.kind == "{" || token.kind == "[" {
      depth += 1
    }
    previous = token.kind
    end = token.end
  }
  if !tokens.is_empty() {
    out.write_string(newline)
  }
  out.to_string()
}

///|
/// Reflow whitespace only. Keys, values, comments, directives and all conditions
/// retain their exact token text. String contents are never indented or rewritten.
pub fn SourceDocument::format_preserving(
  self : SourceDocument,
) -> SourceDocument raise {
  let verbatim : Map[Int32, Int32] = Map([])
  let breaks : Map[Int32, Bool] = Map([])
  for span in self.spans {
    verbatim[span.key_start] = span.key_end
    breaks[span.key_start] = true
    if self.chars[span.value_start] == '{' {
      breaks[span.value_end - 1] = true
    } else {
      verbatim[span.value_start] = span.value_end
    }
  }
  let result = parse_preserving(
    format_layout(self.source, verbatim, breaks, false),
    options=self.options,
  )
  if result.doc != self.doc {
    raise InvalidEdit("Formatting changed KV1 semantics")
  }
  result
}

///|
pub fn KV3SourceDocument::format_preserving(
  self : KV3SourceDocument,
) -> KV3SourceDocument raise {
  let verbatim : Map[Int32, Int32] = Map([])
  let breaks : Map[Int32, Bool] = Map([])
  for _, (start, end) in self.keys {
    verbatim[start] = end
    breaks[start] = true
  }
  for _, span in self.spans {
    if self.chars[span.body] == '{' || self.chars[span.body] == '[' {
      breaks[span.end - 1] = true
      if span.start < span.body {
        let mut end = span.body
        while end > span.start && is_space(self.chars[end - 1]) {
          end -= 1
        }
        verbatim[span.start] = end
      }
    } else {
      verbatim[span.start] = span.end
    }
  }
  // Array children have no key span; each original element gets its own line.
  fn arrays(value : KV3Value, path : Array[Int32]) -> Unit {
    match kv3_unflag(value) {
      KV3Array(values) =>
        for i in 0..<values.length() {
          let child = path + [i]
          breaks[self.spans[index_key(child)].start] = true
          arrays(values[i], child)
        }
      KV3Object(entries) =>
        for i in 0..<entries.length() {
          arrays(entries[i].value, path + [i])
        }
      _ => ()
    }
  }
  arrays(self.doc.root, [])
  let result = parse_kv3_preserving(
    format_layout(self.source, verbatim, breaks, true),
    options=self.options,
    allow_headerless=self.doc.header is None,
  )
  if result.doc != self.doc {
    raise InvalidEdit("Formatting changed KV3 semantics")
  }
  result
}
