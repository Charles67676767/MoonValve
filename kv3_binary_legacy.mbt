///|
priv struct KV3LegacyReader {
  input : ValveBytes
  strings : Array[String]
  options : BinaryOptions
  mut nodes : Int32
}

///|
fn KV3LegacyReader::string(self : KV3LegacyReader) -> String raise BinaryError {
  let id = self.input.uint(4)
  if id < self.strings.length().to_uint64() {
    self.strings[id.to_int()]
  } else {
    ""
  }
}

///|
fn KV3LegacyReader::tag(
  self : KV3LegacyReader,
) -> (Int32, String) raise BinaryError {
  let tag = self.input.uint(1).to_int()
  (
    tag & 127,
    if (tag & 128) != 0 {
      kv3_binary_flag_id(self.input.uint(1).to_int(), 0)
    } else {
      ""
    },
  )
}

///|
fn KV3LegacyReader::value(
  self : KV3LegacyReader,
  tag : Int32,
  flag : String,
  depth : Int32,
) -> KV3BinaryValue raise {
  self.nodes += 1
  if depth > self.options.max_depth || self.nodes > self.options.max_entries {
    raise InvalidBinary(self.input.pos, "Legacy KV3 tree budget exceeded")
  }
  let value : KV3BinaryValue = match tag {
    1 => BNull
    2 => BBool(self.input.uint(1) != 0UL)
    13 | 14 => BBool(tag == 13)
    15 | 16 => BNumber(3, (tag - 15).to_uint64())
    17 | 18 => BNumber(5, (tag - 17).to_double().reinterpret_as_uint64())
    3 | 4 | 5 => BNumber(tag, self.input.uint(8))
    11 | 12 => BNumber(tag, self.input.uint(4))
    6 => BString(self.string())
    7 => BBlob(self.input.take(self.input.count(self.options.max_bytes)))
    8 | 10 => {
      let count = self.input.count(self.options.max_entries - self.nodes)
      let subtype = if tag == 10 { self.tag() } else { (0, "") }
      let children : Array[KV3BinaryValue] = []
      for _ in 0..<count {
        let (kind, annotation) = if tag == 10 { subtype } else { self.tag() }
        children.push(self.value(kind, annotation, depth + 1))
      }
      BArray(children)
    }
    9 => {
      let count = self.input.count(self.options.max_entries - self.nodes)
      let entries : Array[(String, KV3BinaryValue)] = []
      let seen : Map[String, Int32] = Map([])
      for _ in 0..<count {
        let key = self.string()
        let (kind, annotation) = self.tag()
        let child = self.value(kind, annotation, depth + 1)
        if seen.get(key) is Some(i) {
          entries[i] = (key, child)
        } else {
          seen[key] = entries.length()
          entries.push((key, child))
        }
      }
      BObject(entries)
    }
    _ => raise InvalidBinary(self.input.pos, "Unsupported legacy KV3 node")
  }
  if flag.is_empty() {
    value
  } else {
    BFlag(flag, value)
  }
}

///|
fn kv3_legacy_decode(
  input : ValveBytes,
  options : BinaryOptions,
) -> KV3BinaryDocument raise {
  let encoding = kv3_bytes_guid(input.take(16))
  let format_id = kv3_bytes_guid(input.take(16))
  let compression = if encoding == "95791a46-95bc-4f6c-a70b-05bca1b7dfd2" {
    3
  } else if encoding == "6847348a-63a1-4f5c-a197-53806fd9b119" {
    1
  } else if [
      "1b860500-f7d8-40c1-ad82-75a48267e714", "6f620a00-fef0-4305-a35f-042346b1db29",
      "6eb109e6-6b85-4583-a312-703a6e04068c",
    ].contains(encoding) {
    0
  } else {
    raise InvalidBinary(input.pos, "Unknown legacy KV3 encoding")
  }
  let payload = if compression == 1 {
    let size = input.count(options.max_bytes)
    valve_lz4_decode(
      input.take(input.remaining()),
      size,
      b"",
      options.max_bytes,
    )
  } else if compression == 3 {
    let header = input.uint(4)
    let size = (header & 0x7fffffffUL).to_int()
    if size > options.max_bytes {
      raise InvalidBinary(input.pos, "Legacy block output exceeds budget")
    }
    if (header & 0x80000000UL) != 0UL {
      input.take(size)
    } else {
      let output : Array[Byte] = []
      while output.length() < size {
        let mask = input.uint(2).to_int()
        for bit in 0..<16 {
          if output.length() == size {
            break
          }
          if (mask & (1 << bit)) == 0 {
            output.push(input.uint(1).to_byte())
          } else {
            let token = input.uint(2).to_int()
            let distance = (token >> 4) + 1
            let length = (token & 15) + 3
            if distance > output.length() || length > size - output.length() {
              raise InvalidBinary(input.pos, "Invalid legacy block match")
            }
            for _ in 0..<length {
              output.push(output[output.length() - distance])
            }
          }
        }
      }
      Bytes::from_array(output)
    }
  } else {
    input.take(input.remaining())
  }
  if input.remaining() != 0 {
    raise InvalidBinary(input.pos, "Trailing legacy compressed data")
  }
  let reader = valve_bytes(payload)
  let count = reader.count(options.max_entries)
  let strings : Array[String] = []
  for _ in 0..<count {
    strings.push(reader.cstring(options.max_string_bytes))
  }
  let context = KV3LegacyReader::{ input: reader, strings, options, nodes: 0, }
  let (tag, flag) = context.tag()
  let root = context.value(tag, flag, 0)
  if reader.uint(4) != 0xffffffffUL || reader.remaining() != 0 {
    raise InvalidBinary(reader.pos, "Invalid legacy KV3 trailer")
  }
  { version: 0, compression, format_id, root, }
}
