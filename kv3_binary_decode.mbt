///|
priv struct KV3Lanes {
  one : ValveBytes
  two : ValveBytes
  four : ValveBytes
  eight : ValveBytes
}

///|
fn kv3_lanes(
  reader : ValveBytes,
  counts : Array[Int32],
  limit : Int32,
  old_align : Bool,
) -> KV3Lanes raise BinaryError {
  let lanes : Array[ValveBytes] = []
  for i in 0..<4 {
    let width = [1, 2, 4, 8][i]
    if counts[i] < 0 || counts[i] > limit / width {
      raise InvalidBinary(reader.pos, "KV3 lane exceeds budget")
    }
    if counts[i] > 0 {
      reader.take(valve_align(reader.pos, width) - reader.pos) |> ignore
    }
    lanes.push(valve_bytes(reader.take(counts[i] * width)))
  }
  if old_align {
    reader.take(valve_align(reader.pos, 8) - reader.pos) |> ignore
  }
  { one: lanes[0], two: lanes[1], four: lanes[2], eight: lanes[3], }
}

///|
priv struct KV3BinaryContext {
  version : Int32
  lanes : KV3Lanes
  auxiliary : KV3Lanes
  types : ValveBytes
  objects : ValveBytes
  strings : Array[String]
  blobs : Array[Bytes]
  options : BinaryOptions
  mut nodes : Int32
  mut next_blob : Int32
}

///|
fn kv3_binary_flag_id(id : Int32, version : Int32) -> String raise BinaryError {
  if version < 3 {
    if (id & 128) != 0 {
      raise InvalidBinary(0, "Invalid legacy KV3 flag")
    }
    for
      (bit, name) in [
        (1, "resource"),
        (2, "resource_name"),
        (8, "panorama"),
        (16, "soundevent"),
        (32, "subclass"),
      ] {
      if (id & bit) != 0 {
        return name
      }
    }
    ""
  } else {
    if id < 1 || id > 7 {
      raise InvalidBinary(0, "Unknown KV3 flag")
    }
    [
      "", "resource", "resource_name", "panorama", "soundevent", "subclass", "entity_name",
      "localize",
    ][id]
  }
}

///|
fn KV3BinaryContext::tag(
  self : KV3BinaryContext,
) -> (Int32, String) raise BinaryError {
  let raw = self.types.uint(1).to_int()
  let flag = if (raw & 128) != 0 {
    kv3_binary_flag_id(self.types.uint(1).to_int(), self.version)
  } else {
    ""
  }
  if self.version >= 3 && (raw & 64) != 0 {
    self.types.uint(1) |> ignore
  }
  (raw & (if self.version >= 3 { 63 } else { 127 }), flag)
}

///|
fn KV3BinaryContext::string(
  self : KV3BinaryContext,
) -> String raise BinaryError {
  let id = self.lanes.four.uint(4)
  if id < self.strings.length().to_uint64() {
    self.strings[id.to_int()]
  } else {
    ""
  }
}

///|
fn KV3BinaryContext::value(
  self : KV3BinaryContext,
  tag : Int32,
  flag : String,
  lanes : KV3Lanes,
  depth : Int32,
) -> KV3BinaryValue raise {
  self.nodes += 1
  if depth > self.options.max_depth || self.nodes > self.options.max_entries {
    raise InvalidBinary(self.types.pos, "KV3 tree budget exceeded")
  }
  let main = self.lanes
  let value : KV3BinaryValue = match tag {
    1 => BNull
    2 => BBool(lanes.one.uint(1) != 0UL)
    13 => BBool(true)
    14 => BBool(false)
    15 | 16 => BNumber(3, (tag - 15).to_uint64())
    17 | 18 => BNumber(5, (tag - 17).to_double().reinterpret_as_uint64())
    26 | 27 => BNumber(12, (tag - 26).to_uint64())
    3 | 4 | 5 => BNumber(tag, lanes.eight.uint(8))
    11 | 12 | 19 => BNumber(tag, lanes.four.uint(4))
    20 | 21 => BNumber(tag, lanes.two.uint(2))
    22 | 23 => BNumber(tag, lanes.one.uint(1))
    6 => BString(self.string())
    7 =>
      if self.version == 1 {
        BBlob(main.one.take(main.four.count(self.options.max_bytes)))
      } else {
        guard self.blobs.get(self.next_blob) is Some(blob) else {
          raise InvalidBinary(0, "KV3 blob count exhausted")
        }
        self.next_blob += 1
        BBlob(blob)
      }
    8 | 10 | 24 | 25 => {
      let count = if tag == 24 || tag == 25 {
        main.one.uint(1).to_int()
      } else {
        main.four.count(self.options.max_entries)
      }
      if count > self.options.max_entries - self.nodes {
        raise InvalidBinary(0, "Array node budget exceeded")
      }
      let typed = tag != 8
      if typed && self.version >= 2 && count == 0 {
        raise InvalidBinary(0, "Empty typed KV3 array")
      }
      let element_tag = if typed { self.tag() } else { (0, "") }
      let values : Array[KV3BinaryValue] = []
      for _ in 0..<count {
        let (kind, annotation) = if typed { element_tag } else { self.tag() }
        values.push(
          self.value(
            kind,
            annotation,
            if tag == 25 {
              self.auxiliary
            } else {
              main
            },
            depth + 1,
          ),
        )
      }
      BArray(values)
    }
    9 => {
      let count = (if self.version >= 5 { self.objects } else { main.four }).count(
        self.options.max_entries,
      )
      if count > self.options.max_entries - self.nodes {
        raise InvalidBinary(0, "Object node budget exceeded")
      }
      let entries : Array[(String, KV3BinaryValue)] = []
      let seen : Map[String, Int32] = Map([])
      for _ in 0..<count {
        // Modern KV3 stores each property's type before its name's lane read.
        let (kind, annotation) = self.tag()
        let name = self.string()
        let value = self.value(kind, annotation, main, depth + 1)
        if seen.get(name) is Some(index) {
          entries[index] = (name, value)
        } else {
          seen[name] = entries.length()
          entries.push((name, value))
        }
      }
      BObject(entries)
    }
    _ => raise InvalidBinary(self.types.pos, "Unsupported KV3 node type")
  }
  if flag.is_empty() {
    value
  } else {
    BFlag(flag, value)
  }
}

///|
/// Decode lane-encoded KV3 versions 1..5. Legacy VKV3 is dispatched separately.
pub fn decode_kv3_binary(
  bytes : Bytes,
  options~ : BinaryOptions = BinaryOptions::default(),
) -> KV3BinaryDocument raise {
  check_binary_options(options)
  if bytes.length() > options.max_bytes {
    raise InvalidBinary(0, "KV3 input exceeds byte budget")
  }
  let input = valve_bytes(bytes)
  let magic = input.uint(4)
  if magic == 0x03564b56UL {
    return kv3_legacy_decode(input, options)
  }
  let version = (magic & 255UL).to_int()
  if (magic & 0xffffff00UL) != 0x4b563300UL || version < 1 || version > 5 {
    raise InvalidBinary(0, "Unknown binary KV3 version")
  }
  let format_id = kv3_bytes_guid(input.take(16))
  let codec = input.uint(4).to_int()
  if codec < 0 || codec > 2 || (version == 1 && codec == 2) {
    raise InvalidBinary(input.pos, "Unsupported KV3 compression")
  }
  let mut frame_size = 0
  if version >= 2 {
    if input.uint(2) != 0UL {
      raise InvalidBinary(input.pos, "External KV3 compression dictionary")
    }
    frame_size = input.uint(2).to_int()
    if frame_size != (if codec == 1 { 16384 } else { 0 }) {
      raise InvalidBinary(input.pos, "Invalid KV3 compression frame size")
    }
  }
  let c1 = input.count(options.max_bytes)
  let c4 = input.count(options.max_bytes / 4)
  let c8 = input.count(options.max_bytes / 8)
  let mut types_count = 0
  if version >= 2 {
    types_count = input.count(options.max_bytes)
    input.take(4) |> ignore
  }
  let total = input.count(options.max_bytes)
  let compressed = if version == 1 {
    input.remaining()
  } else {
    input.count(options.max_bytes)
  }
  let blocks = if version == 1 { 0 } else { input.count(options.max_entries) }
  let blob_size = if version == 1 { 0 } else { input.count(options.max_bytes) }
  let c2 = if version >= 4 { input.count(options.max_bytes / 2) } else { 0 }
  let block_sizes = if version >= 4 {
    input.count(options.max_bytes)
  } else {
    0
  }
  let size1 = if version >= 5 { input.count(options.max_bytes) } else { total }
  let compressed1 = if version >= 5 {
    input.count(options.max_bytes)
  } else {
    compressed
  }
  let size2 = if version >= 5 { input.count(options.max_bytes) } else { 0 }
  let compressed2 = if version >= 5 {
    input.count(options.max_bytes)
  } else {
    0
  }
  let counts2 : Array[Int32] = []
  let mut object_count = 0
  if version >= 5 {
    for width in [1, 2, 4, 8] {
      counts2.push(input.count(options.max_bytes / width))
    }
    input.uint(4) |> ignore
    object_count = input.count(options.max_entries)
    input.take(8) |> ignore
    if size1 > total || size2 != total - size1 {
      raise InvalidBinary(input.pos, "KV3 buffer sizes disagree")
    }
  }
  if total > options.max_bytes - blob_size {
    raise InvalidBinary(input.pos, "KV3 aggregate decoded budget exceeded")
  }
  let decode1 = size1 + (if version < 5 && codec == 2 { blob_size } else { 0 })
  let payload1 = valve_decompress(
    input.take(if codec == 0 { size1 } else { compressed1 }),
    codec,
    decode1,
    options.max_bytes,
  )
  let buffer1 = valve_bytes(payload1[:size1].to_owned())
  let lanes1 = kv3_lanes(
    buffer1,
    [c1, c2, c4, c8],
    options.max_bytes,
    version < 5,
  )
  let string_count = lanes1.four.count(options.max_entries)
  let strings : Array[String] = []
  let strings_reader = if version >= 5 { lanes1.one } else { buffer1 }
  let string_start = strings_reader.pos
  for _ in 0..<string_count {
    strings.push(strings_reader.cstring(options.max_string_bytes))
  }
  let strings_size = strings_reader.pos - string_start
  if version >= 5 && buffer1.remaining() != 0 {
    raise InvalidBinary(input.pos, "Trailing KV3 string buffer data")
  }
  let mut objects = valve_bytes(b"")
  let mut tail = buffer1
  let lanes = if version >= 5 {
    tail = valve_bytes(
      valve_decompress(
        input.take(if codec == 0 { size2 } else { compressed2 }),
        codec,
        size2,
        options.max_bytes,
      ),
    )
    if object_count > options.max_bytes / 4 {
      raise InvalidBinary(0, "Object lane exceeds budget")
    }
    objects = valve_bytes(tail.take(object_count * 4))
    kv3_lanes(tail, counts2, options.max_bytes, false)
  } else {
    lanes1
  }
  let types_size = if version == 1 {
    tail.remaining() - 4
  } else if version < 5 {
    types_count - strings_size
  } else {
    types_count
  }
  let types = valve_bytes(tail.take(types_size))
  let blobs : Array[Bytes] = []
  let lengths : Array[Int32] = []
  let mut remaining_blob = blob_size
  for _ in 0..<blocks {
    let size = tail.count(remaining_blob)
    remaining_blob -= size
    lengths.push(size)
  }
  if remaining_blob != 0 {
    raise InvalidBinary(tail.pos, "KV3 blob lengths disagree")
  }
  if tail.uint(4) != 0xffeedd00UL {
    raise InvalidBinary(tail.pos, "Invalid KV3 buffer trailer")
  }
  if version >= 5 && tail.remaining() != block_sizes {
    raise InvalidBinary(tail.pos, "KV3 compression size table mismatch")
  }
  if blocks > 0 {
    let raw = if codec == 0 {
      input.take(blob_size)
    } else if codec == 2 {
      if version < 5 {
        payload1[size1:].to_owned()
      } else {
        if compressed1 > compressed || compressed2 > compressed - compressed1 {
          raise InvalidBinary(0, "KV3 compressed size mismatch")
        }
        valve_decompress(
          input.take(compressed - compressed1 - compressed2),
          2,
          blob_size,
          options.max_bytes,
        )
      }
    } else {
      b""
    }
    let chained = @buffer.Buffer()
    let mut dictionary = b""
    if codec == 1 {
      // Historical v4 writers can split the concatenated blob stream rather
      // than individual blobs. Read bounded frames, then apply blob lengths.
      while chained.length() < blob_size {
        let compressed_frame = tail.uint(2).to_int()
        let count = (blob_size - chained.length()).min(frame_size)
        let decoded = valve_lz4_decode(
          input.take(compressed_frame),
          count,
          dictionary,
          options.max_bytes,
          exact=false,
        )
        if decoded.is_empty() {
          raise InvalidBinary(input.pos, "Empty LZ4 blob frame")
        }
        chained.write_bytes(decoded[:])
        let history = @buffer.Buffer()
        history.write_bytes(dictionary[:])
        history.write_bytes(decoded[:])
        let combined = history.to_bytes()
        dictionary = combined[(combined.length() - 65536).max(0):].to_owned()
      }
    }
    let raw_reader = valve_bytes(
      if codec == 1 {
        chained.to_bytes()
      } else {
        raw
      },
    )
    for size in lengths {
      blobs.push(raw_reader.take(size))
    }
    if input.uint(4) != 0xffeedd00UL {
      raise InvalidBinary(input.pos, "Invalid KV3 blob trailer")
    }
  }
  if tail.remaining() != 0 || input.remaining() != 0 {
    raise InvalidBinary(input.pos, "Trailing binary KV3 bytes")
  }
  let context = KV3BinaryContext::{
    version,
    lanes,
    auxiliary: lanes1,
    types,
    objects,
    strings,
    blobs,
    options,
    nodes: 0,
    next_blob: 0,
  }
  let (tag, flag) = context.tag()
  let root = context.value(tag, flag, lanes, 0)
  if types.remaining() != 0 ||
    objects.remaining() != 0 ||
    context.next_blob != blobs.length() {
    raise InvalidBinary(0, "Unused KV3 type/object/blob data")
  }
  for
    lane in [
      lanes.one,
      lanes.two,
      lanes.four,
      lanes.eight,
      lanes1.one,
      lanes1.two,
      lanes1.four,
      lanes1.eight,
    ] {
    if lane.remaining() != 0 {
      raise InvalidBinary(lane.pos, "Unused KV3 numeric lane data")
    }
  }
  { version, compression: codec, format_id, root, }
}
