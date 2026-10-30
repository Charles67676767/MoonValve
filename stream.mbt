///|
/// Raw SAX-style events. Conditions are validated and retained, never evaluated.
/// Returning false for BeginObject suppresses descendants but still validates
/// them and emits the matching EndObject. All other return values are ignored.
pub(all) enum StreamEvent {
  Pair(String, String)
  BeginObject(String)
  EndObject
  Condition(String, String)
} derive(Eq, Debug)

///|
pub extend StreamEvent with Eq::{equal, not_equal}

///|
pub extend StreamEvent with @debug.Debug::{to_repr}

///|
struct StreamParser {
  options : ParseOptions
  visitor : (StreamEvent) -> Bool raise
  mut mode : Int32
  mut phase : Int32
  mut key : String
  parents : Array[String]
  mut skip_depth : Int32
  mut token : StringBuilder
  mut token_chars : Int32
  mut count : Int32
  mut offset : Int32
  mut line : Int32
  mut column : Int32
  mut previous_cr : Bool
  mut assigned : Bool
  mut closed : Bool
  mut input_kind : Int32
  mut pending : Bytes
}

///|
pub fn new_stream_parser(
  visitor : (StreamEvent) -> Bool raise,
  options~ : ParseOptions = ParseOptions::default(),
) -> StreamParser raise ParseError {
  parse("", options~) |> ignore
  if options.conditions is Some(_) {
    raise ParseError({
      code: "invalid_options",
      message: "Stream events retain raw conditions; evaluation requires a document",
      offset: 0,
      line: 1,
      column: 1,
    })
  }
  {
    options,
    visitor,
    mode: 0,
    phase: 0,
    key: "",
    parents: [],
    skip_depth: 0,
    token: StringBuilder(),
    token_chars: 0,
    count: 0,
    offset: 0,
    line: 1,
    column: 1,
    previous_cr: false,
    assigned: false,
    closed: false,
    input_kind: 0,
    pending: b"",
  }
}

///|
fn StreamParser::error(
  self : StreamParser,
  code : String,
  message : String,
) -> Unit raise ParseError {
  self.closed = true
  raise ParseError({
    code,
    message,
    offset: self.offset,
    line: self.line,
    column: self.column,
  })
}

///|
pub fn StreamParser::entries_seen(self : StreamParser) -> Int32 {
  self.count
}

///|
pub fn StreamParser::characters_seen(self : StreamParser) -> Int32 {
  self.offset
}

///|
pub fn StreamParser::feed(self : StreamParser, chunk : String) -> Unit raise {
  if self.input_kind == 2 {
    self.error("input_mode", "Do not mix text and byte chunks")
  }
  self.input_kind = 1
  self.ingest(chunk)
}

///|
/// Strict incremental UTF-8, retaining at most three incomplete bytes between calls.
pub fn StreamParser::feed_bytes(
  self : StreamParser,
  chunk : Bytes,
) -> Unit raise {
  if self.closed {
    self.error("stream_closed", "Stream is closed")
  }
  if self.input_kind == 1 {
    self.error("input_mode", "Do not mix text and byte chunks")
  }
  self.input_kind = 2
  let bytes = self.pending + chunk
  let mut end = bytes.length()
  if end > 0 {
    let mut start = end - 1
    while start > 0 &&
          (bytes[start].to_int() & 0xc0) == 0x80 &&
          end - start <= 3 {
      start -= 1
    }
    let lead = bytes[start].to_int()
    let width = if lead >= 0xc2 && lead <= 0xdf {
      2
    } else if lead >= 0xe0 && lead <= 0xef {
      3
    } else if lead >= 0xf0 && lead <= 0xf4 {
      4
    } else {
      1
    }
    if end - start < width {
      end = start
    }
  }
  let text = @utf8.decode(bytes[:end], ignore_bom=false) catch {
    _ => {
      self.error("invalid_utf8", "Invalid UTF-8 chunk")
      return
    }
  }
  self.pending = bytes[end:].to_owned()
  self.ingest(text)
}

///|
fn StreamParser::ingest(self : StreamParser, chunk : String) -> Unit raise {
  if self.closed {
    self.error("stream_closed", "Stream is closed")
  }
  errdefer {
    self.closed = true
  }
  for c in chunk {
    if self.offset >= self.options.max_input_chars {
      self.error("input_limit", "Input exceeds max_input_chars")
    }
    if c.to_int() == 0 {
      self.error("nul_character", "NUL is not valid KV1 text")
    }
    if !(self.offset == 0 && c.to_int() == 0xfeff) {
      self.consume(c)
    }
    self.offset += 1
    if c == '\r' {
      self.line += 1
      self.column = 1
    } else if c == '\n' {
      if !self.previous_cr {
        self.line += 1
      }
      self.column = 1
    } else {
      self.column += 1
    }
    self.previous_cr = c == '\r'
  }
}

///|
fn StreamParser::append(self : StreamParser, c : Char) -> Unit raise ParseError {
  let limit = if self.mode == 6 { 4096 } else { self.options.max_token_chars }
  if self.token_chars >= limit {
    self.error("token_limit", "Stream token exceeds limit")
  }
  self.token.write_char(c)
  self.token_chars += 1
}

///|
fn StreamParser::emit(self : StreamParser, event : StreamEvent) -> Unit raise {
  if self.skip_depth == 0 {
    (self.visitor)(event) |> ignore
  }
}

///|
fn StreamParser::accept(self : StreamParser) -> Unit raise {
  let text = self.token.to_string()
  self.token = StringBuilder()
  self.token_chars = 0
  self.mode = 0
  if self.phase == 1 {
    self.emit(Pair(self.key, text))
    self.phase = 2
  } else {
    if self.count >= self.options.max_entries {
      self.error("entry_limit", "Input exceeds max_entries")
    }
    self.count += 1
    self.key = text
    self.phase = 1
    self.assigned = false
  }
}

///|
fn StreamParser::consume(self : StreamParser, c : Char) -> Unit raise {
  // At most one reprocessing step is needed for a delimiter or pending slash.
  let mut again = true
  while again {
    again = false
    match self.mode {
      4 => if c == '\n' || c == '\r' { self.mode = 0 }
      3 => {
        match c {
          'n' => self.append('\n')
          'r' => self.append('\r')
          't' => self.append('\t')
          '"' => self.append('"')
          '\\' => self.append('\\')
          _ => self.error("unknown_escape", "Unknown escaped character")
        }
        self.mode = 2
      }
      2 =>
        if c == '"' {
          self.accept()
        } else if c == '\\' && self.options.escape_sequences {
          self.mode = 3
        } else {
          self.append(c)
        }
      1 =>
        if is_space(c) || c == '{' || c == '}' || c == '=' {
          self.accept()
          again = true
        } else if c == '"' {
          self.error("unexpected_quote", "Quote must start at a token boundary")
        } else {
          self.append(c)
        }
      5 =>
        if c == '/' {
          self.mode = 4
        } else {
          self.mode = 1
          self.append('/')
          again = true
        }
      6 =>
        if c == ']' {
          let expression = self.token.to_string()
          let _ = evaluate_condition(expression, []) catch {
            InvalidCondition(message) => {
              self.error("invalid_condition", message)
              false
            }
          }
          self.emit(Condition(self.key, expression))
          self.token = StringBuilder()
          self.token_chars = 0
          self.mode = 0
        } else {
          self.append(c)
        }
      _ => {
        if is_space(c) {
          continue
        }
        match c {
          '/' => self.mode = 5
          '"' => self.mode = 2
          '=' => {
            if self.phase != 1 || self.assigned {
              self.error("expected_string", "Unexpected equals sign")
            }
            self.assigned = true
          }
          '[' => {
            if self.phase == 0 {
              self.error("invalid_condition", "Condition has no preceding key")
            }
            self.mode = 6
          }
          '{' => {
            if self.phase != 1 {
              self.error("expected_string", "Object has no key")
            }
            if self.parents.length() >= self.options.max_depth {
              self.error("depth_limit", "Object exceeds max_depth")
            }
            if self.skip_depth == 0 && !(self.visitor)(BeginObject(self.key)) {
              self.skip_depth = self.parents.length() + 1
            }
            self.parents.push(self.key)
            self.phase = 0
            self.key = ""
            self.assigned = false
          }
          '}' => {
            if self.phase == 1 {
              self.error("missing_value", "Key has no value")
            }
            if self.parents.is_empty() {
              self.error("unexpected_close", "Unexpected closing brace")
            }
            if self.skip_depth == self.parents.length() {
              self.skip_depth = 0
            }
            self.emit(EndObject)
            self.key = self.parents.pop().unwrap()
            self.phase = 2
          }
          _ => {
            self.mode = 1
            self.append(c)
          }
        }
      }
    }
  }
}

///|
pub fn StreamParser::finish(self : StreamParser) -> Unit raise {
  errdefer {
    self.closed = true
  }
  if self.closed {
    self.error("stream_closed", "Stream is closed")
  }
  if !self.pending.is_empty() {
    self.error("invalid_utf8", "Incomplete UTF-8 sequence")
  }
  if self.mode == 1 {
    self.accept()
  }
  if self.mode == 5 {
    self.mode = 1
    self.append('/')
    self.accept()
  }
  if self.mode == 2 || self.mode == 3 {
    self.error("unterminated_string", "Unterminated quoted string")
  }
  if self.mode == 6 {
    self.error("invalid_condition", "Unclosed conditional")
  }
  if self.phase == 1 {
    self.error("missing_value", "Key has no value")
  }
  if !self.parents.is_empty() {
    self.error("unclosed_object", "Object has no closing brace")
  }
  self.closed = true
}
