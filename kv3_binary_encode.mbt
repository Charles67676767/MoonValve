///|
priv struct KV3BinaryWriter {
  one : @buffer.Buffer
  two : @buffer.Buffer
  four : @buffer.Buffer
  eight : @buffer.Buffer
  types : @buffer.Buffer
  objects : @buffer.Buffer
  blobs : Array[Bytes]
  names : Array[String]
  strings : Map[String, Int32]
  version : Int32
  options : BinaryOptions
  mut nodes : Int32
  mut arrays : Int32
  mut object_count : Int32
  mut blob_bytes : Int32
  mut scalar_bytes : Int32
}

///|
fn KV3BinaryWriter::string_id(
  self : KV3BinaryWriter,
  value : String,
) -> UInt64 raise BinaryError {
  if value.is_empty() {
    return 0xffffffffUL
  }
  if self.strings.get(value) is Some(id) {
    return id.to_uint64()
  }
  let size = @utf8.encode(value[:]).length()
  if size > self.options.max_string_bytes ||
    value.contains("\u0000") ||
    size + 1 > self.options.max_bytes - self.scalar_bytes {
    raise InvalidBinary(0, "KV3 string exceeds budget or contains NUL")
  }
  if self.names.length() >= self.options.max_entries {
    raise InvalidBinary(0, "KV3 string table exceeds budget")
  }
  self.scalar_bytes += size + 1
  let id = self.names.length()
  self.strings[value] = id
  self.names.push(value)
  id.to_uint64()
}

///|
fn KV3BinaryWriter::value(
  self : KV3BinaryWriter,
  value : KV3BinaryValue,
  depth : Int32,
  flag : String,
) -> Unit raise {
  if value is BFlag(annotation, inner) {
    if !flag.is_empty() || !kv3_flag(annotation) {
      raise InvalidBinary(0, "Invalid or nested KV3 flag")
    }
    self.value(inner, depth, annotation)
    return
  }
  self.nodes += 1
  if depth > self.options.max_depth || self.nodes > self.options.max_entries {
    raise InvalidBinary(0, "KV3 output tree exceeds budget")
  }
  let tag = match value {
    BNull => 1
    BBool(true) => 13
    BBool(false) => 14
    BNumber(kind, _) => {
      kv3_binary_width(kind) |> ignore
      kind
    }
    BString(_) => 6
    BBlob(_) => 7
    BArray(_) => 8
    BObject(_) => 9
    _ => raise InvalidBinary(0, "Invalid binary KV3 value")
  }
  valve_uint(
    self.types,
    (tag | (if flag.is_empty() { 0 } else { 128 })).to_uint64(),
    1,
  )
  if !flag.is_empty() {
    let flags = [
      "", "resource", "resource_name", "panorama", "soundevent", "subclass", "entity_name",
      "localize",
    ]
    for i in 1..<flags.length() {
      if flags[i] == flag {
        valve_uint(self.types, i.to_uint64(), 1)
        break
      }
    }
  }
  match value {
    BNull | BBool(_) => ()
    BNumber(kind, bits) => {
      let width = kv3_binary_width(kind)
      if width < 8 && bits >= 1UL << (width * 8) {
        raise InvalidBinary(0, "Number payload exceeds storage width")
      }
      self.scalar_bytes += width
      valve_uint(
        match width {
          1 => self.one
          2 => self.two
          4 => self.four
          _ => self.eight
        },
        bits,
        width,
      )
    }
    BString(s) => valve_uint(self.four, self.string_id(s), 4)
    BBlob(bytes) => {
      if bytes.length() > self.options.max_bytes - self.blob_bytes {
        raise InvalidBinary(0, "KV3 blobs exceed budget")
      }
      self.blob_bytes += bytes.length()
      self.blobs.push(bytes)
    }
    BArray(values) => {
      self.arrays += 1
      valve_uint(self.four, values.length().to_uint64(), 4)
      for child in values {
        self.value(child, depth + 1, "")
      }
    }
    BObject(entries) => {
      self.object_count += 1
      valve_uint(
        if self.version >= 5 {
          self.objects
        } else {
          self.four
        },
        entries.length().to_uint64(),
        4,
      )
      let seen : Map[String, Bool] = Map([])
      for (key, child) in entries {
        if seen.contains(key) {
          raise InvalidBinary(0, "Duplicate binary KV3 object member")
        }
        seen[key] = true
        valve_uint(self.four, self.string_id(key), 4)
        self.value(child, depth + 1, "")
      }
    }
    _ => ()
  }
  if self.scalar_bytes > self.options.max_bytes {
    raise InvalidBinary(0, "KV3 output exceeds budget")
  }
}

///|
fn kv3_write_lane(output : @buffer.Buffer, lane : Bytes, width : Int32) -> Unit {
  if lane.is_empty() {
    return
  }
  while output.length() % width != 0 {
    output.write_byte(b'\x00')
  }
  output.write_bytes(lane[:])
}

///|
/// Write interoperable versions 4 or 5. Numbers preserve original storage width
/// and IEEE bits. Container layout is canonical; compressed bytes need not match.
pub fn encode_kv3_binary(
  document : KV3BinaryDocument,
  version~ : Int32 = 5,
  compression~ : Int32 = 0,
  options~ : BinaryOptions = BinaryOptions::default(),
) -> Bytes raise {
  check_binary_options(options)
  if (version != 4 && version != 5) || compression < 0 || compression > 2 {
    raise InvalidBinary(
      0, "KV3 output supports versions 4/5 and compression 0/1/2",
    )
  }
  let writer = KV3BinaryWriter::{
    one: @buffer.Buffer(),
    two: @buffer.Buffer(),
    four: @buffer.Buffer(),
    eight: @buffer.Buffer(),
    types: @buffer.Buffer(),
    objects: @buffer.Buffer(),
    blobs: [],
    names: [],
    strings: Map([]),
    version,
    options,
    nodes: 0,
    arrays: 0,
    object_count: 0,
    blob_bytes: 0,
    scalar_bytes: 0,
  }
  writer.value(document.root, 0, "")
  let strings = @buffer.Buffer()
  for name in writer.names {
    strings.write_bytes(@utf8.encode(name[:])[:])
    strings.write_byte(b'\x00')
  }
  let blob_data = @buffer.Buffer()
  let frame_sizes = @buffer.Buffer()
  for blob in writer.blobs {
    if compression == 1 {
      let mut offset = 0
      while offset < blob.length() {
        let count = (blob.length() - offset).min(16384)
        let encoded = valve_lz4_encode(blob[offset:offset + count].to_owned())
        valve_uint(frame_sizes, encoded.length().to_uint64(), 2)
        blob_data.write_bytes(encoded[:])
        offset += count
      }
    } else {
      blob_data.write_bytes(blob[:])
    }
  }
  let raw_blobs = blob_data.to_bytes()
  let compressed_blobs = if compression == 2 && !writer.blobs.is_empty() {
    valve_compress(raw_blobs, 2)
  } else {
    raw_blobs
  }
  let first = @buffer.Buffer()
  let second = @buffer.Buffer()
  let four = @buffer.Buffer()
  if version == 4 {
    valve_uint(four, writer.names.length().to_uint64(), 4)
  }
  four.write_bytes(writer.four.to_bytes()[:])
  if version == 5 {
    first.write_bytes(strings.to_bytes()[:])
    while first.length() % 4 != 0 {
      first.write_byte(b'\x00')
    }
    valve_uint(first, writer.names.length().to_uint64(), 4)
    second.write_bytes(writer.objects.to_bytes()[:])
  }
  let main = if version == 4 { first } else { second }
  kv3_write_lane(main, writer.one.to_bytes(), 1)
  kv3_write_lane(main, writer.two.to_bytes(), 2)
  kv3_write_lane(main, four.to_bytes(), 4)
  kv3_write_lane(main, writer.eight.to_bytes(), 8)
  if version == 4 {
    while main.length() % 8 != 0 {
      main.write_byte(b'\x00')
    }
    main.write_bytes(strings.to_bytes()[:])
  }
  main.write_bytes(writer.types.to_bytes()[:])
  for blob in writer.blobs {
    valve_uint(main, blob.length().to_uint64(), 4)
  }
  valve_uint(main, 0xffeedd00UL, 4)
  main.write_bytes(frame_sizes.to_bytes()[:])
  if first.length() > options.max_bytes - second.length() ||
    writer.blob_bytes > options.max_bytes - first.length() - second.length() {
    raise InvalidBinary(0, "KV3 aggregate output exceeds budget")
  }
  let packed1 = valve_compress(first.to_bytes(), compression)
  let packed2 = if version == 5 {
    valve_compress(second.to_bytes(), compression)
  } else {
    b""
  }
  let output = @buffer.Buffer()
  valve_uint(output, 0x4b563300UL + version.to_uint64(), 4)
  output.write_bytes(kv3_guid_bytes(document.format_id)[:])
  valve_uint(output, compression.to_uint64(), 4)
  valve_uint(output, 0UL, 2)
  valve_uint(output, if compression == 1 { 16384UL } else { 0UL }, 2)
  valve_uint(
    output,
    (if version == 5 { strings.length() } else { writer.one.length() }).to_uint64(),
    4,
  )
  valve_uint(
    output,
    (if version == 5 { 1 } else { four.length() / 4 }).to_uint64(),
    4,
  )
  valve_uint(
    output,
    (if version == 5 { 0 } else { writer.eight.length() / 8 }).to_uint64(),
    4,
  )
  valve_uint(
    output,
    (writer.types.length() + (if version == 4 { strings.length() } else { 0 })).to_uint64(),
    4,
  )
  valve_uint(output, writer.object_count.min(65535).to_uint64(), 2)
  valve_uint(output, writer.arrays.min(65535).to_uint64(), 2)
  valve_uint(output, (first.length() + second.length()).to_uint64(), 4)
  valve_uint(
    output,
    (packed1.length() +
    packed2.length() +
    (if compression == 2 { compressed_blobs.length() } else { 0 })).to_uint64(),
    4,
  )
  valve_uint(output, writer.blobs.length().to_uint64(), 4)
  valve_uint(output, writer.blob_bytes.to_uint64(), 4)
  valve_uint(
    output,
    (if version == 4 { writer.two.length() / 2 } else { 0 }).to_uint64(),
    4,
  )
  valve_uint(
    output,
    (if version == 5 { frame_sizes.length() } else { 0 }).to_uint64(),
    4,
  )
  if version == 5 {
    for
      n in [
        first.length(),
        if compression == 0 {
          0
        } else {
          packed1.length()
        },
        second.length(),
        if compression == 0 {
          0
        } else {
          packed2.length()
        },
        writer.one.length(),
        writer.two.length() / 2,
        four.length() / 4,
        writer.eight.length() / 8,
        writer.nodes,
        writer.object_count,
        writer.arrays,
        writer.nodes,
      ] {
      valve_uint(output, n.to_uint64(), 4)
    }
  }
  output.write_bytes(packed1[:])
  output.write_bytes(packed2[:])
  output.write_bytes(compressed_blobs[:])
  if !writer.blobs.is_empty() {
    valve_uint(output, 0xffeedd00UL, 4)
  }
  if output.length() > options.max_bytes {
    raise InvalidBinary(0, "KV3 encoded bytes exceed budget")
  }
  output.to_bytes()
}
