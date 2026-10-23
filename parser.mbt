///|
priv struct Parser {
  chars : Array[Char]
  options : ParseOptions
  mut pos : Int
  mut line : Int
  mut column : Int
  mut entry_count : Int
}

///|
/// Parse the documented KV1 text subset; unsupported file-loading directives
/// and platform conditionals are rejected rather than silently misinterpreted.
pub fn parse(
  input : String,
  options? : ParseOptions = ParseOptions::default(),
) -> Document raise ParseError {
  if options.max_depth < 0 ||
    options.max_depth > 256 ||
    options.max_entries < 0 ||
    options.max_input_chars < 0 ||
    options.max_token_chars < 0 {
    raise ParseError({
      code: "invalid_options",
      message: "Limits must be nonnegative; max_depth must be at most 256",
      offset: 0,
      line: 1,
      column: 1,
    })
  }
  if input.char_length() > options.max_input_chars {
    raise ParseError({
      code: "input_limit",
      message: "Input exceeds max_input_chars",
      offset: 0,
      line: 1,
      column: 1,
    })
  }
  let p = Parser::{
    chars: input.to_array(),
    options,
    pos: 0,
    line: 1,
    column: 1,
    entry_count: 0,
  }
  if p.chars.get(0) is Some(c) && c.to_int() == 0xFEFF {
    p.advance()
  }
  { entries: p.read_entries(0, false), }
}

///|
fn Parser::fail(
  self : Parser,
  code : String,
  message : String,
) -> Unit raise ParseError {
  raise ParseError({
    code,
    message,
    offset: self.pos,
    line: self.line,
    column: self.column,
  })
}

///|
fn Parser::peek(self : Parser) -> Char? {
  self.chars.get(self.pos)
}

///|
fn Parser::advance(self : Parser) -> Unit {
  guard self.pos < self.chars.length() else { return }
  let c = self.chars[self.pos]
  self.pos = self.pos + 1
  if c == '\r' {
    self.line = self.line + 1
    self.column = 1
  } else if c == '\n' {
    if self.pos < 2 || self.chars[self.pos - 2] != '\r' {
      self.line = self.line + 1
    }
    self.column = 1
  } else {
    self.column = self.column + 1
  }
}

///|
fn is_space(c : Char) -> Bool {
  c == ' ' ||
  c == '\t' ||
  c == '\r' ||
  c == '\n' ||
  c.to_int() == 0x0B ||
  c.to_int() == 0x0C
}

///|
fn Parser::skip_trivia(self : Parser) -> Unit raise ParseError {
  while self.pos < self.chars.length() {
    let c = self.chars[self.pos]
    if c.to_int() == 0 {
      self.fail("nul_character", "NUL characters are not valid KV1 text")
    } else if is_space(c) {
      self.advance()
    } else if c == '/' && self.chars.get(self.pos + 1) == Some('/') {
      while self.peek() is Some(ch) && ch != '\r' && ch != '\n' {
        self.advance()
      }
    } else {
      break
    }
  }
}

///|
fn Parser::read_string(self : Parser) -> String raise ParseError {
  self.skip_trivia()
  guard self.peek() is Some(first) else {
    self.fail("expected_string", "Expected a key or string value")
    return ""
  }
  if first == '{' || first == '}' {
    self.fail("expected_string", "Expected a string, found an object delimiter")
  }
  let quoted = first == '"'
  if quoted {
    self.advance()
  }
  let builder = StringBuilder()
  let mut count = 0
  while self.peek() is Some(c) {
    if quoted && c == '"' {
      self.advance()
      return builder.to_string()
    }
    if !quoted && (is_space(c) || c == '{' || c == '}' || c == '=') {
      return builder.to_string()
    }
    if c.to_int() == 0 {
      self.fail("nul_character", "NUL characters are not valid KV1 text")
    }
    if !quoted && c == '"' {
      self.fail(
        "unexpected_quote", "A quoted string must begin at a token boundary",
      )
    }
    if count >= self.options.max_token_chars {
      self.fail("token_limit", "String exceeds max_token_chars")
    }
    if quoted && c == '\\' && self.options.escape_sequences {
      self.advance()
      guard self.peek() is Some(escaped) else {
        self.fail("unterminated_string", "Backslash at end of quoted string")
        return ""
      }
      match escaped {
        'n' => builder.write_char('\n')
        'r' => builder.write_char('\r')
        't' => builder.write_char('\t')
        '\\' => builder.write_char('\\')
        '"' => builder.write_char('"')
        _ =>
          self.fail(
            "unknown_escape", "Unknown escape; use literal mode for unescaped paths",
          )
      }
      self.advance()
    } else {
      builder.write_char(c)
      self.advance()
    }
    count = count + 1
  }
  if quoted {
    self.fail(
      "unterminated_string", "Quoted string is missing its closing quote",
    )
  }
  builder.to_string()
}

///|
fn Parser::read_entries(
  self : Parser,
  depth : Int,
  nested : Bool,
) -> Array[Entry] raise ParseError {
  let entries : Array[Entry] = []
  while true {
    self.skip_trivia()
    match self.peek() {
      None => {
        if nested {
          self.fail("unclosed_object", "Object is missing its closing brace")
        }
        return entries
      }
      Some('}') => {
        if !nested {
          self.fail("unexpected_close", "Closing brace has no matching object")
        }
        self.advance()
        return entries
      }
      Some('[') =>
        self.fail(
          "unsupported_conditional", "Platform conditionals are not supported",
        )
      _ => ()
    }
    if self.entry_count >= self.options.max_entries {
      self.fail("entry_limit", "Document exceeds max_entries")
    }
    let key = self.read_string()
    if key.is_empty() && self.peek() == Some('=') {
      self.fail("expected_string", "Unexpected equals sign")
    }
    if key.equal_ignore_ascii_case("#include") ||
      key.equal_ignore_ascii_case("#base") {
      self.fail(
        "unsupported_directive", "Include/base directives require an explicit file resolver",
      )
    }
    self.entry_count = self.entry_count + 1
    self.skip_trivia()
    let mut keep = true
    while self.peek() == Some('[') {
      keep = self.read_condition()
      self.skip_trivia()
    }
    let mut override_previous = false
    if self.peek() == Some('=') {
      self.advance()
      self.skip_trivia()
      while self.peek() == Some('[') {
        keep = self.read_condition()
        override_previous = true
        self.skip_trivia()
      }
    }
    let value = match self.peek() {
      Some('{') => {
        if depth >= self.options.max_depth {
          self.fail("depth_limit", "Document exceeds max_depth")
        }
        self.advance()
        Value::Object(self.read_entries(depth + 1, true))
      }
      None | Some('}') => {
        self.fail("missing_value", "Key has no value")
        Value::Text("")
      }
      _ => Value::Text(self.read_string())
    }
    self.skip_trivia()
    while self.peek() == Some('[') {
      keep = self.read_condition()
      self.skip_trivia()
    }
    if keep {
      if override_previous {
        let mut index = 0
        while index < entries.length() {
          if entries[index].key.equal_ignore_ascii_case(key) {
            entries.remove(index) |> ignore
          } else {
            index += 1
          }
        }
      }
      entries.push({ key, value, })
    }
  }
  entries
}

///|
fn Parser::read_condition(self : Parser) -> Bool raise ParseError {
  guard self.options.conditions is Some(symbols) else {
    self.fail(
      "unsupported_conditional", "Pass an explicit conditions array to evaluate platform conditions",
    )
    return false
  }
  self.advance()
  let text = StringBuilder()
  let mut count = 0
  while self.peek() is Some(c) && c != ']' {
    if count >= 4096 {
      self.fail("condition_limit", "Conditional exceeds 4096 characters")
    }
    text.write_char(c)
    count += 1
    self.advance()
  }
  if self.peek() != Some(']') {
    self.fail("invalid_condition", "Missing closing bracket")
  }
  self.advance()
  evaluate_condition(text.to_string(), symbols) catch {
    InvalidCondition(message) => {
      self.fail("invalid_condition", message)
      false
    }
  }
}
