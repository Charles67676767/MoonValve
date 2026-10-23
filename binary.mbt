///|
/// Typed standard binary KV1. Floating-point payloads retain their exact bits,
/// including NaN payloads and negative zero. Pointer values are data, never dereferenced.
pub(all) enum BinaryValue {
  ObjectValue(Array[BinaryEntry])
  StringValue(String)
  Int32Value(Int)
  Float32Bits(UInt)
  Pointer32(UInt)
  WideString(String)
  Color32(UInt)
  UInt64Value(UInt64)
  Int64Value(Int64)
} derive(Eq, Debug)

///|
pub(all) struct BinaryEntry {
  key : String
  value : BinaryValue
} derive(Eq, Debug)

///|
pub(all) struct BinaryOptions {
  max_depth : Int
  max_entries : Int
  max_bytes : Int
  max_string_bytes : Int
} derive(Eq, Debug)

///|
pub fn BinaryOptions::default() -> BinaryOptions {
  {
    max_depth: 128,
    max_entries: 100000,
    max_bytes: 16777216,
    max_string_bytes: 1048576,
  }
}

///|
pub suberror BinaryError {
  InvalidBinary(Int, String)
} derive(Debug)

///|
pub extend BinaryValue with Eq::{equal, not_equal}

///|
pub extend BinaryValue with @debug.Debug::{to_repr}

///|
pub extend BinaryEntry with Eq::{equal, not_equal}

///|
pub extend BinaryEntry with @debug.Debug::{to_repr}

///|
pub extend BinaryOptions with Eq::{equal, not_equal}

///|
pub extend BinaryOptions with @debug.Debug::{to_repr}

///|
pub extend BinaryError with @debug.Debug::{to_repr}

///|
fn check_binary_options(options : BinaryOptions) -> Unit raise BinaryError {
  if options.max_depth < 0 ||
    options.max_depth > 128 ||
    options.max_entries < 0 ||
    options.max_bytes < 1 ||
    options.max_string_bytes < 0 {
    raise InvalidBinary(0, "Invalid binary resource limits")
  }
}

///|
priv struct BinaryReader {
  bytes : Bytes
  options : BinaryOptions
  mut pos : Int
  mut count : Int
  table : Array[String]?
}

///|
/// Decode standard KV1 with marker 8. Reject truncated streams, trailing bytes,
/// invalid encodings and unknown types. Appinfo containers and VBKV are separate formats.
pub fn decode_binary(
  bytes : Bytes,
  options? : BinaryOptions = BinaryOptions::default(),
  string_table? : Array[String]? = None,
) -> Array[BinaryEntry] raise BinaryError {
  check_binary_options(options)
  if bytes.length() > options.max_bytes {
    raise InvalidBinary(0, "Input exceeds byte limit")
  }
  validate_string_table(string_table, options) |> ignore
  let reader = BinaryReader::{
    bytes,
    options,
    pos: 0,
    count: 0,
    table: string_table,
  }
  let entries = reader.read_binary_entries(0)
  if reader.pos != bytes.length() {
    raise InvalidBinary(reader.pos, "Trailing bytes after root terminator")
  }
  entries
}

///|
fn BinaryReader::byte(self : BinaryReader) -> Int raise BinaryError {
  guard self.bytes.get(self.pos) is Some(value) else {
    raise InvalidBinary(self.pos, "Unexpected end of binary input")
  }
  self.pos += 1
  value.to_int()
}

///|
fn BinaryReader::number(
  self : BinaryReader,
  width : Int,
) -> UInt64 raise BinaryError {
  let mut value = 0UL
  for i in 0..<width {
    value = value | (self.byte().to_uint64() << (i * 8))
  }
  value
}

///|
fn BinaryReader::cstring(
  self : BinaryReader,
  wide : Bool,
) -> String raise BinaryError {
  let start = self.pos
  let width = if wide { 2 } else { 1 }
  while true {
    let first = self.byte()
    let second = if wide { self.byte() } else { 0 }
    if first == 0 && second == 0 {
      break
    }
    if self.pos - start > self.options.max_string_bytes {
      raise InvalidBinary(start, "String exceeds byte limit")
    }
  }
  let view = self.bytes[start:self.pos - width]
  try {
    if wide {
      @utf16.decode(view, ignore_bom=false, endianness=@utf16.Little)
    } else {
      @utf8.decode(view, ignore_bom=false)
    }
  } catch {
    _ => raise InvalidBinary(start, "Malformed string encoding")
  }
}

///|
fn BinaryReader::read_binary_entries(
  self : BinaryReader,
  depth : Int,
) -> Array[BinaryEntry] raise BinaryError {
  let entries : Array[BinaryEntry] = []
  while true {
    let offset = self.pos
    let tag = self.byte()
    if tag == 8 {
      return entries
    }
    if tag < 0 || tag > 10 || tag == 8 || tag == 9 {
      raise InvalidBinary(offset, "Unknown binary type")
    }
    if self.count >= self.options.max_entries {
      raise InvalidBinary(offset, "Entry limit exceeded")
    }
    self.count += 1
    let key = match self.table {
      None => self.cstring(false)
      Some(table) => {
        let index = self.number(4)
        if index >= table.length().to_uint64() {
          raise InvalidBinary(
            self.pos - 4,
            "String table index is out of range",
          )
        }
        table[index.to_int()]
      }
    }
    let value = match tag {
      0 => {
        if depth >= self.options.max_depth {
          raise InvalidBinary(offset, "Object depth limit exceeded")
        }
        BinaryValue::ObjectValue(self.read_binary_entries(depth + 1))
      }
      1 => StringValue(self.cstring(false))
      2 => Int32Value(self.number(4).to_uint().reinterpret_as_int())
      3 => Float32Bits(self.number(4).to_uint())
      4 => Pointer32(self.number(4).to_uint())
      5 => WideString(self.cstring(true))
      6 => Color32(self.number(4).to_uint())
      7 => UInt64Value(self.number(8))
      10 => Int64Value(self.number(8).reinterpret_as_int64())
      _ => raise InvalidBinary(offset, "Unknown binary type")
    }
    entries.push({ key, value, })
  }
  entries
}

///|
priv struct BinaryWriter {
  buffer : @buffer.Buffer
  options : BinaryOptions
  mut count : Int
  table : Map[String, Int]?
}

///|
fn BinaryWriter::check_size(
  self : BinaryWriter,
  addition : Int,
) -> Unit raise BinaryError {
  if addition > self.options.max_bytes - self.buffer.length() {
    raise InvalidBinary(self.buffer.length(), "Output exceeds byte limit")
  }
}

///|
fn BinaryWriter::string(
  self : BinaryWriter,
  text : String,
  wide : Bool,
) -> Unit raise BinaryError {
  if text.char_length() > self.options.max_string_bytes ||
    text.contains("\u0000") {
    raise InvalidBinary(
      self.buffer.length(),
      "String exceeds limit or contains NUL",
    )
  }
  let bytes = if wide {
    @utf16.encode(text[:], endianness=@utf16.Little)
  } else {
    @utf8.encode(text[:])
  }
  if bytes.length() > self.options.max_string_bytes {
    raise InvalidBinary(self.buffer.length(), "String exceeds byte limit")
  }
  self.check_size(bytes.length() + (if wide { 2 } else { 1 }))
  self.buffer.write_bytes(bytes[:])
  self.buffer.write_byte(0)
  if wide {
    self.buffer.write_byte(0)
  }
}

///|
/// Encode with the same limits as decoding. Order, duplicate keys and numeric
/// types survive a decode/encode round trip without coercion through JSON numbers.
pub fn encode_binary(
  entries : Array[BinaryEntry],
  options? : BinaryOptions = BinaryOptions::default(),
  string_table? : Array[String]? = None,
) -> Bytes raise BinaryError {
  check_binary_options(options)
  let table = validate_string_table(string_table, options)
  let writer = BinaryWriter::{
    buffer: @buffer.Buffer(),
    options,
    count: 0,
    table,
  }
  writer.write_binary_entries(entries, 0)
  writer.buffer.to_bytes()
}

///|
fn BinaryWriter::write_binary_entries(
  self : BinaryWriter,
  entries : Array[BinaryEntry],
  depth : Int,
) -> Unit raise BinaryError {
  for entry in entries {
    if self.count >= self.options.max_entries {
      raise InvalidBinary(self.buffer.length(), "Entry limit exceeded")
    }
    self.count += 1
    let tag = match entry.value {
      ObjectValue(_) => 0
      StringValue(_) => 1
      Int32Value(_) => 2
      Float32Bits(_) => 3
      Pointer32(_) => 4
      WideString(_) => 5
      Color32(_) => 6
      UInt64Value(_) => 7
      Int64Value(_) => 10
    }
    self.check_size(1)
    self.buffer.write_byte(tag.to_byte())
    match self.table {
      None => self.string(entry.key, false)
      Some(table) => {
        guard table.get(entry.key) is Some(index) else {
          raise InvalidBinary(
            self.buffer.length(),
            "Key is absent from string table",
          )
        }
        self.check_size(4)
        self.buffer.write_uint_le(index.reinterpret_as_uint())
      }
    }
    match entry.value {
      ObjectValue(children) => {
        if depth >= self.options.max_depth {
          raise InvalidBinary(
            self.buffer.length(),
            "Object depth limit exceeded",
          )
        }
        self.write_binary_entries(children, depth + 1)
      }
      StringValue(s) => self.string(s, false)
      WideString(s) => self.string(s, true)
      Int32Value(n) => {
        self.check_size(4)
        self.buffer.write_int_le(n)
      }
      Float32Bits(n) | Pointer32(n) | Color32(n) => {
        self.check_size(4)
        self.buffer.write_uint_le(n)
      }
      UInt64Value(n) => {
        self.check_size(8)
        self.buffer.write_uint64_le(n)
      }
      Int64Value(n) => {
        self.check_size(8)
        self.buffer.write_int64_le(n)
      }
    }
  }
  self.check_size(1)
  self.buffer.write_byte(8)
}

///|
fn validate_string_table(
  table : Array[String]?,
  options : BinaryOptions,
) -> Map[String, Int]? raise BinaryError {
  guard table is Some(strings) else { return None }
  if strings.length() > 1000000 {
    raise InvalidBinary(0, "String table has too many entries")
  }
  let result : Map[String, Int] = Map([])
  let mut total = 0
  for i in 0..<strings.length() {
    let text = strings[i]
    if text.char_length() > options.max_string_bytes || text.contains("\u0000") {
      raise InvalidBinary(0, "Invalid string table entry")
    }
    let length = @utf8.encode(text[:]).length()
    if length > options.max_string_bytes || length > options.max_bytes - total {
      raise InvalidBinary(0, "String table exceeds byte budget")
    }
    total += length
    if result.contains(text) {
      raise InvalidBinary(0, "Duplicate string table entry")
    }
    result[text] = i
  }
  Some(result)
}
