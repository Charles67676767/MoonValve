///|
priv enum DMXToken {
  DToken(String)
  DPunctuation(Char)
  DEnd
} derive(Eq)

///|
priv struct DMXTextReader {
  chars : Array[Char]
  mut pos : Int
  mut pending : DMXToken?
  elements : Array[DMXElement]
  options : BinaryOptions
  mut values : Int
}

///|
fn DMXTextReader::token(self : DMXTextReader) -> DMXToken raise {
  if self.pending is Some(token) {
    self.pending = None
    return token
  }
  while self.pos < self.chars.length() {
    let c = self.chars[self.pos]
    if [' ', '\n', '\r', '\t'].contains(c) {
      self.pos += 1
      continue
    }
    if c == '/' && self.chars.get(self.pos + 1) == Some('/') {
      while self.pos < self.chars.length() && self.chars[self.pos] != '\n' {
        self.pos += 1
      }
      continue
    }
    if c == '/' && self.chars.get(self.pos + 1) == Some('*') {
      self.pos += 2
      while self.pos + 1 < self.chars.length() &&
            !(self.chars[self.pos] == '*' && self.chars[self.pos + 1] == '/') {
        self.pos += 1
      }
      if self.pos + 1 >= self.chars.length() {
        raise InvalidBinary(self.pos, "Unclosed DMX comment")
      }
      self.pos += 2
      continue
    }
    self.pos += 1
    if ['{', '}', '[', ']', ','].contains(c) {
      return DPunctuation(c)
    }
    if c != '"' {
      raise InvalidBinary(self.pos - 1, "DMX text tokens must be quoted")
    }
    let start = self.pos - 1
    let mut escaped = false
    while self.pos < self.chars.length() {
      let current = self.chars[self.pos]
      self.pos += 1
      if current == '"' && !escaped {
        let text = po_unquote(
          String::from_array(self.chars[start:self.pos].to_owned()),
        )
        if @utf8.encode(text[:]).length() > self.options.max_string_bytes {
          raise InvalidBinary(start, "DMX string exceeds budget")
        }
        return DToken(text)
      }
      if current == '\\' && !escaped {
        escaped = true
      } else {
        escaped = false
      }
    }
    raise InvalidBinary(start, "Unclosed DMX string")
  }
  DEnd
}

///|
fn DMXTextReader::peek(self : DMXTextReader) -> DMXToken raise {
  let token = self.token()
  self.pending = Some(token)
  token
}

///|
fn DMXTextReader::string(self : DMXTextReader) -> String raise {
  guard self.token() is DToken(text) else {
    raise InvalidBinary(self.pos, "Expected DMX string")
  }
  text
}

///|
fn DMXTextReader::expect(self : DMXTextReader, c : Char) -> Unit raise {
  if self.token() != DPunctuation(c) {
    raise InvalidBinary(self.pos, "Unexpected DMX punctuation")
  }
}

///|
fn dmx_float_bits(text : String) -> UInt raise {
  match text.to_lower() {
    "nan" => 0x7fc00000U
    "inf" | "+inf" | "infinity" => 0x7f800000U
    "-inf" | "-infinity" => 0xff800000U
    _ => {
      let number = @strconv.parse_double(text[:])
      if number == 0.0 && text.trim_start().has_prefix("-") {
        0x80000000U
      } else {
        Float::from_double(number).reinterpret_as_uint()
      }
    }
  }
}

///|
fn dmx_words(text : String) -> Array[String] {
  text
  .replace_all(old="\t", new=" ")
  .replace_all(old="\r", new=" ")
  .replace_all(old="\n", new=" ")
  .split(" ")
  .filter(s => !s.is_empty())
  .map(s => s.to_owned())
  .collect()
}

///|
fn dmx_scalar_text(tag : Int, text : String) -> DMXValue raise {
  match tag {
    1 => DElement(if text.is_empty() { None } else { Some(dmx_uuid(text)) })
    2 => DInt(@strconv.parse_int(text[:]))
    3 => DFloatBits(dmx_float_bits(text))
    4 =>
      match text.to_lower() {
        "1" | "true" => DBool(true)
        "0" | "false" => DBool(false)
        _ => raise InvalidBinary(0, "Invalid DMX boolean")
      }
    5 => DString(text)
    6 => {
      let chars = text
        .to_array()
        .filter(c => ![' ', '\t', '\n', '\r'].contains(c))
      if chars.length() % 2 != 0 {
        raise InvalidBinary(0, "Odd DMX blob hex length")
      }
      let output = @buffer.Buffer()
      for i in 0..<(chars.length() / 2) {
        guard kv3_hex(chars[2 * i]) is Some(a) &&
          kv3_hex(chars[2 * i + 1]) is Some(b) else {
          raise InvalidBinary(0, "Invalid DMX blob hex")
        }
        output.write_byte((a * 16 + b).to_byte())
      }
      DBinary(output.to_bytes())
    }
    7 => {
      let ticks = @strconv.parse_double(text[:]) * 10000.0
      if ticks.is_nan() || ticks < -2147483648.0 || ticks > 2147483647.0 {
        raise InvalidBinary(0, "DMX time exceeds tick range")
      }
      DTime(ticks.round().to_int())
    }
    8 => {
      let parts = dmx_words(text)
      if parts.length() != 4 {
        raise InvalidBinary(0, "DMX color requires RGBA")
      }
      let mut bits = 0U
      for i in 0..<4 {
        let n = @strconv.parse_int(parts[i][:])
        if n < 0 || n > 255 {
          raise InvalidBinary(0, "DMX color channel outside byte range")
        }
        bits = bits | (n.reinterpret_as_uint() << (i * 8))
      }
      DColor(bits)
    }
    9..=14 => {
      let parts = dmx_words(text)
      if parts.length() != [2, 3, 4, 3, 4, 16][tag - 9] {
        raise InvalidBinary(0, "DMX vector dimension mismatch")
      }
      DVector(tag, parts.map(dmx_float_bits))
    }
    _ => raise InvalidBinary(0, "Unsupported DMX text type")
  }
}

///|
fn DMXTextReader::element(
  self : DMXTextReader,
  kind : String,
  depth : Int,
) -> String raise {
  if depth > self.options.max_depth ||
    self.elements.length() >= self.options.max_entries {
    raise InvalidBinary(self.pos, "DMX element/depth budget exceeded")
  }
  self.expect('{')
  let index = self.elements.length()
  let placeholder = "#" + index.to_string()
  self.elements.push({ id: placeholder, name: "", kind, attributes: [], })
  let mut id = placeholder
  let mut name = ""
  let mut named = false
  let attributes : Array[DMXAttribute] = []
  while self.peek() != DPunctuation('}') {
    let key = self.string()
    let type_name = self.string()
    let lower = type_name.to_lower()
    if key == "id" && lower == "elementid" {
      if id != placeholder {
        raise InvalidBinary(self.pos, "Duplicate DMX element id")
      }
      id = dmx_uuid(self.string())
      continue
    }
    if key == "name" {
      if lower != "string" || named {
        raise InvalidBinary(self.pos, "Invalid/duplicate DMX element name")
      }
      name = self.string()
      named = true
      continue
    }
    self.values += 1
    if self.values > self.options.max_entries {
      raise InvalidBinary(self.pos, "DMX value budget exceeded")
    }
    let array = lower.has_suffix("_array")
    let base = if array { lower[:lower.length() - 6].to_owned() } else { lower }
    let mut tag = 0
    let types = dmx_types()
    for i in 1..<types.length() {
      if types[i] == base {
        tag = i
        break
      }
    }
    let value = if tag == 0 {
      if array || self.peek() != DPunctuation('{') {
        raise InvalidBinary(self.pos, "Unknown DMX attribute type")
      }
      DElement(Some(self.element(type_name, depth + 1)))
    } else if array {
      self.expect('[')
      let values : Array[DMXValue] = []
      while self.peek() != DPunctuation(']') {
        self.values += 1
        if self.values > self.options.max_entries {
          raise InvalidBinary(self.pos, "DMX array budget exceeded")
        }
        let value = if tag == 1 {
          let token = self.string()
          if token.to_lower() == "element" {
            dmx_scalar_text(1, self.string())
          } else {
            DElement(Some(self.element(token, depth + 1)))
          }
        } else {
          dmx_scalar_text(tag, self.string())
        }
        values.push(value)
        if self.peek() == DPunctuation(',') {
          self.token() |> ignore
        }
      }
      self.expect(']')
      DArray(tag, values)
    } else {
      dmx_scalar_text(tag, self.string())
    }
    attributes.push({ name: key, value, })
  }
  self.expect('}')
  self.elements[index] = { id, name, kind, attributes, }
  id
}

///|
fn dmx_fix_reference(value : DMXValue, ids : Map[String, String]) -> DMXValue {
  match value {
    DElement(Some(id)) => DElement(Some(ids.get(id).unwrap_or(id)))
    DArray(tag, values) =>
      DArray(tag, values.map(v => dmx_fix_reference(v, ids)))
    _ => value
  }
}

///|
fn dmx_read_text(
  text : String,
  format_name : String,
  format_version : Int,
  options : BinaryOptions,
) -> DMXDocument raise {
  let reader = DMXTextReader::{
    chars: text.to_array(),
    pos: 0,
    pending: None,
    elements: [],
    options,
    values: 0,
  }
  while reader.peek() != DEnd {
    reader.element(reader.string(), 0) |> ignore
  }
  if reader.elements.is_empty() {
    raise InvalidBinary(0, "Empty DMX graph")
  }
  let existing : Map[String, Bool] = Map([])
  for element in reader.elements {
    if !element.id.has_prefix("#") {
      existing[element.id] = true
    }
  }
  let generated : Map[String, String] = Map([])
  let mut ordinal = 1
  for element in reader.elements {
    if element.id.has_prefix("#") {
      while true {
        let hex = ordinal.to_string(radix=16)
        ordinal += 1
        let candidate = "00000000-0000-4000-8000-" +
          String::make(12 - hex.length(), '0') +
          hex
        if !existing.contains(candidate) {
          existing[candidate] = true
          generated[element.id] = candidate
          break
        }
      }
    }
  }
  let elements = reader.elements.map(e => {
    ..e,
    id: generated.get(e.id).unwrap_or(e.id),
    attributes: e.attributes.map(a => {
      ..a,
      value: dmx_fix_reference(a.value, generated),
    }),
  })
  let doc = { format_name, format_version, root: elements[0].id, elements, }
  dmx_validate(doc, options)
  doc
}

///|
pub fn read_dmx(
  bytes : Bytes,
  options? : BinaryOptions = BinaryOptions::default(),
) -> DMXDocument raise {
  check_binary_options(options)
  if bytes.length() > options.max_bytes {
    raise InvalidBinary(0, "DMX input exceeds byte budget")
  }
  let mut end = 0
  while end + 2 < bytes.length() &&
        end < 512 &&
        bytes[end:end + 3].to_owned() != b"-->" {
    end += 1
  }
  if end + 2 >= bytes.length() || end >= 512 {
    raise InvalidBinary(0, "Missing/oversized DMX header")
  }
  let header = @utf8.decode(bytes[:end], ignore_bom=false)
  if !header.has_prefix("<!--") {
    raise InvalidBinary(0, "Expected DMX header")
  }
  let parts = dmx_words(header[4:].to_owned())
  if parts.length() != 7 ||
    parts[0] != "dmx" ||
    parts[1] != "encoding" ||
    parts[4] != "format" {
    raise InvalidBinary(0, "Unsupported DMX header")
  }
  let version = @strconv.parse_int(parts[3][:])
  let format_version = @strconv.parse_int(parts[6][:])
  let payload = valve_bytes(bytes)
  payload.pos = end + 3
  match parts[2] {
    "binary" | "unicode_binary" =>
      dmx_read_binary(payload, version, parts[5], format_version, options)
    "keyvalues2" | "unicode_keyvalues2" if version == 1 =>
      dmx_read_text(
        @utf8.decode(bytes[payload.pos:], ignore_bom=false),
        parts[5],
        format_version,
        options,
      )
    _ => raise InvalidBinary(0, "Unsupported DMX encoding/version")
  }
}

///|
fn dmx_scalar_string(value : DMXValue) -> String raise {
  match value {
    DElement(id) => id.unwrap_or("")
    DString(s) => s
    DInt(n) => n.to_string()
    DFloatBits(bits) =>
      kv3_binary_float(Float::reinterpret_from_uint(bits).to_double())
    DBool(b) => if b { "1" } else { "0" }
    DBinary(bytes) =>
      match kv3_binary_pack(BBlob(bytes), 0) {
        Object(fields) =>
          match fields["value"] {
            String(s) => s
            _ => ""
          }
        _ => ""
      }
    DTime(ticks) => (ticks.to_double() / 10000.0).to_string()
    DColor(bits) =>
      Array::makei(4, i => ((bits >> (8 * i)) & 255U).to_string()).join(" ")
    DVector(_, bits) =>
      bits
      .map(n => kv3_binary_float(Float::reinterpret_from_uint(n).to_double()))
      .join(" ")
    DArray(_, _) => raise InvalidBinary(0, "Expected a scalar DMX value")
  }
}

///|
/// Flat KeyValues2 retains UUID graph identity, cycles and shared references.
/// IEEE NaN payloads belong to binary serialization; text normalizes them.
pub fn stringify_dmx(
  document : DMXDocument,
  options? : BinaryOptions = BinaryOptions::default(),
) -> String raise {
  dmx_validate(document, options)
  let output = StringBuilder()
  output.write_string(
    "<!-- dmx encoding keyvalues2 1 format " +
    document.format_name +
    " " +
    document.format_version.to_string() +
    " -->\n",
  )
  let elements = [document.element(document.root).unwrap()] +
    document.elements.filter(e => e.id != document.root)
  let types = dmx_types()
  for element in elements {
    output.write_string(
      po_quote(element.kind) +
      "\n{\n\t\"id\" \"elementid\" " +
      po_quote(element.id) +
      "\n\t\"name\" \"string\" " +
      po_quote(element.name) +
      "\n",
    )
    for attribute in element.attributes {
      output.write_string("\t" + po_quote(attribute.name) + " ")
      let tag = dmx_type(attribute.value)
      if attribute.value is DArray(_, values) {
        output.write_string(po_quote(types[tag] + "_array") + "\n\t[\n")
        for value in values {
          output.write_string(
            "\t\t" +
            (if tag == 1 { "\"element\" " } else { "" }) +
            po_quote(dmx_scalar_string(value)) +
            ",\n",
          )
        }
        output.write_string("\t]\n")
      } else {
        output.write_string(
          po_quote(types[tag]) +
          " " +
          po_quote(dmx_scalar_string(attribute.value)) +
          "\n",
        )
      }
    }
    output.write_string("}\n")
  }
  let text = output.to_string()
  if @utf8.encode(text[:]).length() > options.max_bytes {
    raise InvalidBinary(0, "DMX text output exceeds byte budget")
  }
  text
}
