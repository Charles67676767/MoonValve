///|
pub(all) enum KV3Value {
  KV3Null
  KV3Bool(Bool)
  KV3Integer(String)
  KV3Float(String)
  KV3String(String)
  KV3Blob(Bytes)
  KV3Array(Array[KV3Value])
  KV3Object(Array[KV3Entry])
  KV3Flag(String, KV3Value)
} derive(Eq, Debug)

///|
pub(all) struct KV3Entry {
  key : String
  value : KV3Value
} derive(Eq, Debug)

///|
pub(all) struct KV3Header {
  format_name : String
  format_id : String
} derive(Eq, Debug)

///|
pub(all) struct KV3Document {
  header : KV3Header?
  root : KV3Value
} derive(Eq, Debug)

///|
pub extend KV3Value with Eq::{equal, not_equal}

///|
pub extend KV3Value with @debug.Debug::{to_repr}

///|
pub extend KV3Entry with Eq::{equal, not_equal}

///|
pub extend KV3Entry with @debug.Debug::{to_repr}

///|
pub extend KV3Header with Eq::{equal, not_equal}

///|
pub extend KV3Header with @debug.Debug::{to_repr}

///|
pub extend KV3Document with Eq::{equal, not_equal}

///|
pub extend KV3Document with @debug.Debug::{to_repr}

///|
pub fn generic_kv3_header() -> KV3Header {
  { format_name: "generic", format_id: "7412167c-06e9-4698-aff2-e63eb59037e7", }
}

///|
priv struct KV3Reader {
  chars : Array[Char]
  options : ParseOptions
  mut pos : Int
  mut line : Int
  mut column : Int
  mut nodes : Int
  path : Array[Int]
  spans : Map[String, KV3Span]?
  keys : Map[String, (Int, Int)]
}

///|
fn KV3Reader::fail(self : KV3Reader, message : String) -> Unit raise ParseError {
  raise ParseError({
    code: "kv3_syntax",
    message,
    offset: self.pos,
    line: self.line,
    column: self.column,
  })
}

///|
fn KV3Reader::peek(self : KV3Reader) -> Char? {
  self.chars.get(self.pos)
}

///|
fn KV3Reader::advance(self : KV3Reader) -> Unit raise ParseError {
  if self.pos >= self.chars.length() {
    self.fail("Unexpected end of KV3")
  }
  let c = self.chars[self.pos]
  if c.to_int() == 0 {
    self.fail("NUL is not accepted in KV3 text")
  }
  self.pos += 1
  if c == '\r' {
    self.line += 1
    self.column = 1
  } else if c == '\n' {
    if self.pos < 2 || self.chars[self.pos - 2] != '\r' {
      self.line += 1
    }
    self.column = 1
  } else {
    self.column += 1
  }
}

///|
fn KV3Reader::space(self : KV3Reader) -> Unit raise ParseError {
  while self.peek() is Some(c) {
    if is_space(c) {
      self.advance()
      continue
    }
    if c == '/' && self.chars.get(self.pos + 1) == Some('/') {
      self.advance()
      self.advance()
      let mut previous = ' '
      while self.peek() is Some(next) {
        if next == '\n' || next == '\r' {
          self.advance()
          if next == '\r' && self.peek() == Some('\n') {
            self.advance()
          }
          if previous != '\\' {
            break
          }
          previous = ' '
        } else {
          previous = next
          self.advance()
        }
      }
    } else if c == '/' && self.chars.get(self.pos + 1) == Some('*') {
      self.advance()
      self.advance()
      while !(self.peek() == Some('*') &&
            self.chars.get(self.pos + 1) == Some('/')) {
        if self.peek() is None {
          self.fail("Unclosed block comment")
        }
        self.advance()
      }
      self.advance()
      self.advance()
    } else {
      break
    }
  }
}

///|
fn KV3Reader::take(self : KV3Reader, wanted : Char) -> Unit raise ParseError {
  self.space()
  if self.peek() != Some(wanted) {
    self.fail("Expected '\{wanted}'")
  }
  self.advance()
}

///|
fn KV3Reader::word(self : KV3Reader) -> String raise ParseError {
  self.space()
  let begin = self.pos
  while self.peek() is Some(c) &&
        c.to_int() > 32 &&
        c.to_int() < 128 &&
        !"{}[]=,'\":|;".contains(c.to_string()) &&
        !(c == '/' &&
        (
          self.chars.get(self.pos + 1) == Some('/') ||
          self.chars.get(self.pos + 1) == Some('*')
        )) {
    self.advance()
    if self.pos - begin > self.options.max_token_chars {
      self.fail("Token exceeds KV3 limit")
    }
  }
  if self.pos == begin {
    self.fail("Expected an unquoted KV3 token")
  }
  String::from_array(self.chars[begin:self.pos].to_owned())
}

///|
fn kv3_identifier(text : String) -> Bool {
  !text.is_empty() &&
  !(text[0] >= '0' && text[0] <= '9') &&
  text.all(c => {
    (c >= 'a' && c <= 'z') ||
    (c >= 'A' && c <= 'Z') ||
    (c >= '0' && c <= '9') ||
    c == '_' ||
    c == '.'
  })
}

///|
fn kv3_hex(c : Char) -> Int? {
  if c >= '0' && c <= '9' {
    Some(c.to_int() - 48)
  } else if c >= 'a' && c <= 'f' {
    Some(c.to_int() - 87)
  } else if c >= 'A' && c <= 'F' {
    Some(c.to_int() - 55)
  } else {
    None
  }
}

///|
fn kv3_guid(text : String) -> Bool {
  let chars = text.to_array()
  chars.length() == 36 &&
  chars
  .mapi((i, c) => {
    if [8, 13, 18, 23].contains(i) {
      c == '-'
    } else {
      kv3_hex(c) is Some(_)
    }
  })
  .all(b => b)
}

///|
fn KV3Reader::expect_word(
  self : KV3Reader,
  expected : String,
) -> Unit raise ParseError {
  if !self.word().equal_ignore_ascii_case(expected) {
    self.fail("Expected header token " + expected)
  }
}

///|
fn KV3Reader::header(self : KV3Reader) -> KV3Header raise ParseError {
  self.expect_word("<!--")
  self.expect_word("kv3")
  self.expect_word("encoding")
  self.take(':')
  self.expect_word("text")
  self.take(':')
  self.expect_word("version")
  self.take('{')
  if !self
    .word()
    .equal_ignore_ascii_case("e21c7f3c-8a33-41c5-9977-a76d3a32aa0d") {
    self.fail("Unsupported KV3 text encoding GUID")
  }
  self.take('}')
  self.expect_word("format")
  self.take(':')
  let format_name = self.word()
  if format_name.length() > 128 || !kv3_identifier(format_name) {
    self.fail("Invalid KV3 format name")
  }
  self.take(':')
  self.expect_word("version")
  self.take('{')
  let format_id = self.word()
  if !kv3_guid(format_id) {
    self.fail("Invalid format GUID")
  }
  if format_name.equal_ignore_ascii_case("generic") &&
    !format_id.equal_ignore_ascii_case(generic_kv3_header().format_id) {
    self.fail("Unsupported generic format GUID")
  }
  self.take('}')
  self.expect_word("-->")
  { format_name, format_id, }
}

///|
fn KV3Reader::string(self : KV3Reader) -> String raise ParseError {
  self.space()
  let quote = self.peek().unwrap()
  self.advance()
  if quote == '"' &&
    self.peek() == Some('"') &&
    self.chars.get(self.pos + 1) == Some('"') {
    self.advance()
    self.advance()
    if self.peek() == Some('\r') {
      self.advance()
    }
    if self.peek() != Some('\n') {
      self.fail("Triple quotes require an opening newline")
    }
    self.advance()
    let begin = self.pos
    let mut start_of_line = true
    let mut previous = ' '
    while true {
      if start_of_line &&
        self.peek() == Some('"') &&
        self.chars.get(self.pos + 1) == Some('"') &&
        self.chars.get(self.pos + 2) == Some('"') {
        let mut end = self.pos
        if end > begin && self.chars[end - 1] == '\n' {
          end -= 1
        }
        if end > begin && self.chars[end - 1] == '\r' {
          end -= 1
        }
        let value = String::from_array(self.chars[begin:end].to_owned())
          .replace_all(old="\r\n", new="\n")
          .replace_all(old="\\\"\"\"", new="\"\"\"")
        self.advance()
        self.advance()
        self.advance()
        return value
      }
      if self.peek() is None {
        self.fail("Unclosed multiline string")
      }
      let c = self.peek().unwrap()
      self.advance()
      start_of_line = c == '\n' &&
        previous != '\\' &&
        !(previous == '\r' && self.pos >= 3 && self.chars[self.pos - 3] == '\\')
      previous = c
      if self.pos - begin > self.options.max_token_chars {
        self.fail("Multiline string exceeds KV3 token limit")
      }
    }
  }
  let output = StringBuilder()
  let mut size = 0
  while self.peek() is Some(c) {
    self.advance()
    if c == quote {
      return output.to_string()
    }
    if c == '\\' {
      guard self.peek() is Some(escaped) else {
        self.fail("Incomplete string escape")
        return ""
      }
      self.advance()
      output.write_char(
        match escaped {
          'n' => '\n'
          't' => '\t'
          _ => escaped
        },
      )
    } else {
      output.write_char(c)
    }
    size += 1
    if size > self.options.max_token_chars {
      self.fail("String exceeds KV3 token limit")
    }
  }
  self.fail("Unclosed KV3 string")
  ""
}

///|
fn kv3_flag(text : String) -> Bool {
  [
    "resource", "resource_name", "panorama", "soundevent", "subclass", "entity_name",
    "localize",
  ].contains(text.to_lower())
}

///|
fn kv3_number(text : String) -> KV3Value raise WriteError {
  let lower = text.to_lower()
  if ["nan", "inf", "+inf", "-inf"].contains(lower) {
    return KV3Float(text)
  }
  let digits = if text.has_prefix("-") || text.has_prefix("+") {
    text[1:].to_owned()
  } else {
    text
  }
  if decimal_id(digits) {
    try {
      if text.has_prefix("-") {
        @strconv.parse_int64(text[:]) |> ignore
      } else {
        @strconv.parse_uint64(digits[:]) |> ignore
      }
    } catch {
      _ => raise InvalidDocument("KV3 integer exceeds 64-bit range")
    }
    return KV3Integer(text)
  }
  if text.is_empty() ||
    !text.all(c => "+-.0123456789eE".contains(c.to_string())) {
    raise InvalidDocument("Invalid KV3 number")
  }
  let number = @strconv.parse_double(text[:]) catch {
    _ => raise InvalidDocument("Invalid KV3 floating-point literal")
  }
  if number.is_inf() || number.is_nan() {
    raise InvalidDocument(
      "Floating-point overflow; use an explicit inf literal",
    )
  }
  KV3Float(text)
}

///|
fn KV3Reader::value(self : KV3Reader, depth : Int) -> KV3Value raise {
  self.space()
  let start = self.pos
  let value = self.value_inner(depth)
  if self.spans is Some(spans) {
    let key = index_key(self.path)
    let body = spans.get(key).map(s => s.body).unwrap_or(start)
    spans[key] = { start, end: self.pos, body, }
  }
  value
}

///|
fn KV3Reader::value_inner(self : KV3Reader, depth : Int) -> KV3Value raise {
  self.space()
  if depth > self.options.max_depth {
    self.fail("KV3 depth limit exceeded")
  }
  self.nodes += 1
  if self.nodes > self.options.max_entries {
    self.fail("KV3 node limit exceeded")
  }
  match self.peek() {
    Some('{') => {
      self.advance()
      let entries : Array[KV3Entry] = []
      let keys : Map[String, Bool] = Map([])
      while true {
        self.space()
        if self.peek() == Some('}') {
          self.advance()
          break
        }
        let key_start = self.pos
        let quoted = self.peek() == Some('"') || self.peek() == Some('\'')
        let key = if quoted { self.string() } else { self.word() }
        let key_end = self.pos
        if !quoted && !kv3_identifier(key) {
          self.fail("Unquoted object keys must be identifiers")
        }
        if keys.contains(key) {
          self.fail("Duplicate KV3 object key")
        }
        keys[key] = true
        self.take('=')
        self.path.push(entries.length())
        if self.spans is Some(_) {
          self.keys[index_key(self.path)] = (key_start, key_end)
        }
        let value = self.value(depth + 1)
        self.path.pop() |> ignore
        entries.push({ key, value, })
      }
      KV3Object(entries)
    }
    Some('[') => {
      self.advance()
      let values : Array[KV3Value] = []
      self.space()
      while self.peek() != Some(']') {
        self.path.push(values.length())
        let value = self.value(depth + 1)
        self.path.pop() |> ignore
        values.push(value)
        self.space()
        if self.peek() == Some(']') {
          break
        }
        self.take(',')
        self.space()
      }
      self.take(']')
      KV3Array(values)
    }
    Some('#') => {
      self.advance()
      self.take('[')
      let output = @buffer.Buffer()
      while true {
        self.space()
        if self.peek() == Some(']') {
          self.advance()
          break
        }
        let token = self.word().to_array()
        guard token.length() == 2 &&
          kv3_hex(token[0]) is Some(a) &&
          kv3_hex(token[1]) is Some(b) else {
          self.fail("Blob bytes require two hexadecimal digits")
          return KV3Null
        }
        if output.length() >= self.options.max_token_chars {
          self.fail("Blob exceeds KV3 token limit")
        }
        output.write_byte((a * 16 + b).to_byte())
      }
      KV3Blob(output.to_bytes())
    }
    Some('"') | Some('\'') => KV3String(self.string())
    None => {
      self.fail("Expected a KV3 value")
      KV3Null
    }
    _ => {
      let token = self.word()
      let token_end = self.pos
      let token_line = self.line
      let token_column = self.column
      self.space()
      if self.peek() == Some(':') || self.peek() == Some('|') {
        if !kv3_flag(token) {
          self.fail("Unknown KV3 flag")
        }
        self.advance()
        let value = self.value(depth + 1)
        if value is KV3Flag(_, _) {
          self.fail("A value cannot have stacked flags")
        }
        return KV3Flag(token.to_lower(), value)
      }
      self.pos = token_end
      self.line = token_line
      self.column = token_column
      match token.to_lower() {
        "null" => KV3Null
        "true" => KV3Bool(true)
        "false" => KV3Bool(false)
        _ =>
          kv3_number(token) catch {
            _ => {
              self.fail("Invalid KV3 literal; strings must be quoted")
              KV3Null
            }
          }
      }
    }
  }
}

///|
/// Text KV3 only. Limits reuse ParseOptions; KV1 condition/literal modes are invalid.
pub fn parse_kv3(
  input : String,
  options? : ParseOptions = ParseOptions::default(),
  allow_headerless? : Bool = false,
) -> KV3Document raise {
  kv3_read(input, options, allow_headerless, None).0
}

///|
fn kv3_read(
  input : String,
  options : ParseOptions,
  allow_headerless : Bool,
  spans : Map[String, KV3Span]?,
) -> (KV3Document, KV3Reader) raise {
  parse("", options~) |> ignore
  if !options.escape_sequences || options.conditions is Some(_) {
    raise InvalidDocument("KV3 does not use KV1 literal or condition options")
  }
  if input.char_length() > options.max_input_chars {
    raise InvalidDocument("KV3 input exceeds character budget")
  }
  let reader = KV3Reader::{
    chars: input.to_array(),
    options,
    pos: 0,
    line: 1,
    column: 1,
    nodes: 0,
    path: [],
    spans,
    keys: Map([]),
  }
  if reader.peek() == Some('\uFEFF') {
    reader.advance()
  }
  reader.space()
  let header = if reader.peek() == Some('<') {
    Some(reader.header())
  } else if allow_headerless {
    None
  } else {
    reader.fail("Expected KV3 text header")
    None
  }
  let root = reader.value(0)
  reader.space()
  if reader.peek() is Some(_) {
    reader.fail("Trailing data after root value")
  }
  ({ header, root, }, reader)
}

///|
fn kv3_write_string(
  output : StringBuilder,
  text : String,
) -> Unit raise WriteError {
  if text.char_length() > 1048576 {
    raise InvalidDocument("KV3 string exceeds token limit")
  }
  output.write_char('"')
  for c in text {
    match c {
      '"' => output.write_string("\\\"")
      '\\' => output.write_string("\\\\")
      '\n' => output.write_string("\\n")
      '\t' => output.write_string("\\t")
      _ => {
        if c.to_int() == 0 {
          raise InvalidDocument("NUL in KV3 string")
        }
        output.write_char(c)
      }
    }
  }
  output.write_char('"')
}

///|
fn kv3_write_value(
  output : StringBuilder,
  value : KV3Value,
  depth : Int,
  count : Ref[Int],
) -> Unit raise {
  count.val += 1
  if depth > 128 || count.val > 100000 {
    raise InvalidDocument("KV3 writer resource limit exceeded")
  }
  match value {
    KV3Null => output.write_string("null")
    KV3Bool(b) => output.write_string(if b { "true" } else { "false" })
    KV3String(s) => kv3_write_string(output, s)
    KV3Integer(text) => {
      if !(kv3_number(text) is KV3Integer(_)) {
        raise InvalidDocument("Invalid KV3 integer")
      }
      output.write_string(text)
    }
    KV3Float(text) => {
      if !(kv3_number(text) is KV3Float(_)) {
        raise InvalidDocument(
          "Float literals must contain a decimal point, exponent, or special keyword",
        )
      }
      output.write_string(text)
    }
    KV3Flag(flag, value) => {
      if !kv3_flag(flag) || value is KV3Flag(_, _) {
        raise InvalidDocument("Invalid KV3 flag")
      }
      output.write_string(flag.to_lower() + ":")
      kv3_write_value(output, value, depth + 1, count)
    }
    KV3Blob(bytes) => {
      if bytes.length() > 1048576 {
        raise InvalidDocument("KV3 blob exceeds token limit")
      }
      output.write_string("#[")
      for byte in bytes {
        let digits = "0123456789abcdef"
        output.write_char(digits[byte.to_int() / 16].to_char().unwrap())
        output.write_char(digits[byte.to_int() % 16].to_char().unwrap())
        output.write_char(' ')
      }
      output.write_char(']')
    }
    KV3Array(values) => {
      output.write_string("[")
      for i in 0..<values.length() {
        if i > 0 {
          output.write_string(", ")
        }
        kv3_write_value(output, values[i], depth + 1, count)
      }
      output.write_string("]")
    }
    KV3Object(entries) => {
      output.write_string("{\n")
      let seen : Map[String, Bool] = Map([])
      for entry in entries {
        if seen.contains(entry.key) {
          raise InvalidDocument("Duplicate KV3 key")
        }
        seen[entry.key] = true
        write_indent(output, depth + 1)
        kv3_write_string(output, entry.key)
        output.write_string(" = ")
        kv3_write_value(output, entry.value, depth + 1, count)
        output.write_string("\n")
      }
      write_indent(output, depth)
      output.write_string("}")
    }
  }
}

///|
pub fn stringify_kv3(document : KV3Document) -> String raise {
  kv3_check_size(document.root, 0, { val: 8387584, }, { val: 0, })
  let output = StringBuilder()
  if document.header is Some(header) {
    if header.format_name.length() > 128 ||
      !kv3_identifier(header.format_name) ||
      !kv3_guid(header.format_id) ||
      (
        header.format_name.equal_ignore_ascii_case("generic") &&
        !header.format_id.equal_ignore_ascii_case(
          generic_kv3_header().format_id,
        )
      ) {
      raise InvalidDocument("Invalid KV3 format header")
    }
    output.write_string(
      "<!-- kv3 encoding:text:version{e21c7f3c-8a33-41c5-9977-a76d3a32aa0d} format:" +
      header.format_name +
      ":version{" +
      header.format_id +
      "} -->\n",
    )
  }
  kv3_write_value(output, document.root, 0, { val: 0, })
  output.write_string("\n")
  let text = output.to_string()
  parse_kv3(text, allow_headerless=document.header is None) |> ignore
  text
}

///|
fn kv3_check_size(
  value : KV3Value,
  depth : Int,
  budget : Ref[Int],
  nodes : Ref[Int],
) -> Unit raise WriteError {
  nodes.val += 1
  if depth > 128 || nodes.val > 100000 {
    raise InvalidDocument("KV3 writer resource limit exceeded")
  }
  let mut size = 2 * (depth + 1) + 8
  match value {
    KV3String(s) | KV3Integer(s) | KV3Float(s) => {
      let chars = s.char_length()
      if chars > 1048576 {
        raise InvalidDocument("KV3 token exceeds limit")
      }
      size += chars * 2
    }
    KV3Blob(bytes) => {
      if bytes.length() > 1048576 {
        raise InvalidDocument("KV3 blob exceeds limit")
      }
      size += bytes.length() * 3
    }
    KV3Object(entries) =>
      for entry in entries {
        let chars = entry.key.char_length()
        if chars > 1048576 || chars * 2 + 4 > budget.val {
          raise InvalidDocument("KV3 output exceeds writer budget")
        }
        budget.val -= chars * 2 + 4
        kv3_check_size(entry.value, depth + 1, budget, nodes)
      }
    KV3Array(values) =>
      for child in values {
        kv3_check_size(child, depth + 1, budget, nodes)
      }
    KV3Flag(_, child) => {
      size += 20
      kv3_check_size(child, depth + 1, budget, nodes)
    }
    _ => ()
  }
  if size > budget.val {
    raise InvalidDocument("KV3 output exceeds writer budget")
  }
  budget.val -= size
}
