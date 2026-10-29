///|
/// Shared bounded byte cursor for Valve archive and resource containers.
priv struct ValveBytes {
  data : Bytes
  mut pos : Int
}

///|
fn valve_bytes(data : Bytes) -> ValveBytes {
  { data, pos: 0, }
}

///|
fn ValveBytes::remaining(self : ValveBytes) -> Int {
  self.data.length() - self.pos
}

///|
fn ValveBytes::take(self : ValveBytes, count : Int) -> Bytes raise BinaryError {
  if count < 0 || count > self.remaining() {
    raise InvalidBinary(self.pos, "Truncated Valve byte range")
  }
  let result = self.data[self.pos:self.pos + count].to_owned()
  self.pos += count
  result
}

///|
fn ValveBytes::uint(self : ValveBytes, width : Int) -> UInt64 raise BinaryError {
  if width < 1 || width > 8 || width > self.remaining() {
    raise InvalidBinary(self.pos, "Truncated integer")
  }
  let mut n = 0UL
  for i in 0..<width {
    n = n | (self.data[self.pos + i].to_uint64() << (i * 8))
  }
  self.pos += width
  n
}

///|
fn ValveBytes::count(self : ValveBytes, limit : Int) -> Int raise BinaryError {
  let n = self.uint(4)
  if n > limit.to_uint64() {
    raise InvalidBinary(self.pos - 4, "Count exceeds resource budget")
  }
  n.to_int()
}

///|
fn ValveBytes::cstring(
  self : ValveBytes,
  limit : Int,
) -> String raise BinaryError {
  let start = self.pos
  while self.pos < self.data.length() && self.data[self.pos] != b'\x00' {
    self.pos += 1
    if self.pos - start > limit {
      raise InvalidBinary(start, "String exceeds byte budget")
    }
  }
  if self.pos == self.data.length() {
    raise InvalidBinary(start, "Unterminated string")
  }
  let result = @utf8.decode(self.data[start:self.pos], ignore_bom=false) catch {
    _ => raise InvalidBinary(start, "Invalid UTF-8")
  }
  self.pos += 1
  result
}

///|
fn valve_uint(output : @buffer.Buffer, n : UInt64, width : Int) -> Unit {
  for i in 0..<width {
    output.write_byte(((n >> (i * 8)) & 255UL).to_byte())
  }
}

///|
fn valve_align(n : Int, alignment : Int) -> Int {
  (n + alignment - 1) / alignment * alignment
}

///|
/// Raw LZ4 block decoder, including overlapping matches and an optional chain
/// dictionary. A frame cannot consume bytes outside its explicit input range.
fn valve_lz4_decode(
  input : Bytes,
  expected : Int,
  dictionary : Bytes,
  limit : Int,
  exact? : Bool = true,
) -> Bytes raise BinaryError {
  if expected < 0 || expected > limit || dictionary.length() > 65536 {
    raise InvalidBinary(0, "Invalid LZ4 output budget")
  }
  let reader = valve_bytes(input)
  let output : Array[Byte] = dictionary.to_array()
  let base = output.length()
  fn length(initial : Int) -> Int raise BinaryError {
    let mut n = initial
    if initial == 15 {
      while true {
        let next = reader.uint(1).to_int()
        if next > limit - n {
          raise InvalidBinary(reader.pos, "LZ4 length exceeds budget")
        }
        n += next
        if next != 255 {
          break
        }
      }
    }
    n
  }
  while reader.remaining() > 0 {
    let token = reader.uint(1).to_int()
    let literals = length(token >> 4)
    if literals > expected - (output.length() - base) {
      raise InvalidBinary(reader.pos, "LZ4 literal overflow")
    }
    for byte in reader.take(literals) {
      output.push(byte)
    }
    if reader.remaining() == 0 {
      break
    }
    let distance = reader.uint(2).to_int()
    if distance == 0 || distance > output.length() {
      raise InvalidBinary(reader.pos, "Invalid LZ4 match distance")
    }
    let count = length(token & 15) + 4
    if count > expected - (output.length() - base) {
      raise InvalidBinary(reader.pos, "LZ4 match exceeds output")
    }
    for _ in 0..<count {
      output.push(output[output.length() - distance])
    }
  }
  if exact && output.length() - base != expected {
    raise InvalidBinary(reader.pos, "LZ4 output length mismatch")
  }
  Bytes::from_array(output[base:].to_owned())
}

///|
/// Deterministic raw LZ4 with a bounded hash table and 64 KiB match window.
/// Leave five trailing literals and stop match starts twelve bytes before EOF.
fn valve_lz4_encode(input : Bytes) -> Bytes {
  let output = @buffer.Buffer()
  let table : FixedArray[Int] = FixedArray::make(65536, -1)
  fn extension(rest : Int) {
    let mut rest = rest
    while rest >= 255 {
      output.write_byte(b'\xff')
      rest -= 255
    }
    output.write_byte(rest.to_byte())
  }
  fn hash(pos : Int) -> Int {
    let mut word = 0U
    for i in 0..<4 {
      word = word | (input[pos + i].to_int().reinterpret_as_uint() << (8 * i))
    }
    ((word * 2654435761U) >> 16).reinterpret_as_int()
  }
  let mut cursor = 0
  let mut anchor = 0
  while cursor <= input.length() - 12 {
    let h = hash(cursor)
    let previous = table[h]
    table[h] = cursor
    if previous < 0 ||
      cursor - previous > 65535 ||
      input[previous:previous + 4].to_owned() !=
      input[cursor:cursor + 4].to_owned() {
      cursor += 1
      continue
    }
    let mut count = 4
    while cursor + count < input.length() - 5 &&
          input[previous + count] == input[cursor + count] {
      count += 1
    }
    let literals = cursor - anchor
    output.write_byte(((literals.min(15) << 4) | (count - 4).min(15)).to_byte())
    if literals >= 15 {
      extension(literals - 15)
    }
    output.write_bytes(input[anchor:cursor])
    valve_uint(output, (cursor - previous).to_uint64(), 2)
    if count - 4 >= 15 {
      extension(count - 19)
    }
    cursor += count
    anchor = cursor
    if cursor >= 2 && cursor + 2 < input.length() {
      table[hash(cursor - 2)] = cursor - 2
    }
  }
  let literals = input.length() - anchor
  output.write_byte((literals.min(15) << 4).to_byte())
  if literals >= 15 {
    extension(literals - 15)
  }
  output.write_bytes(input[anchor:])
  output.to_bytes()
}

///|
fn valve_decompress(
  input : Bytes,
  codec : Int,
  expected : Int,
  limit : Int,
) -> Bytes raise {
  if expected < 0 || expected > limit || input.length() > limit {
    raise InvalidBinary(0, "Compression budget exceeded")
  }
  let result = match codec {
    0 => input
    1 => valve_lz4_decode(input, expected, b"", limit)
    2 => valve_zstd_decode(input, expected, limit)
    _ => raise InvalidBinary(0, "Unknown compression codec")
  }
  if result.length() != expected {
    raise InvalidBinary(0, "Decompressed size mismatch")
  }
  result
}

///|
fn valve_compress(input : Bytes, codec : Int) -> Bytes raise {
  match codec {
    0 => input
    1 => valve_lz4_encode(input)
    2 => @zstd.compress(input)
    _ => raise InvalidBinary(0, "Unknown compression codec")
  }
}

///|
/// Validate every frame's declared window and boundary before invoking the
/// streaming decoder. Concatenated frames are decoded separately and bounded.
fn valve_zstd_decode(input : Bytes, expected : Int, limit : Int) -> Bytes raise {
  let reader = valve_bytes(input)
  let output = @buffer.Buffer()
  while reader.remaining() > 0 {
    let start = reader.pos
    if reader.uint(4) != 0xfd2fb528UL {
      raise InvalidBinary(start, "Expected a Zstandard frame")
    }
    let descriptor = reader.uint(1).to_int()
    if (descriptor & 24) != 0 {
      raise InvalidBinary(start, "Reserved Zstandard frame bits")
    }
    let single = (descriptor & 32) != 0
    if !single {
      let w = reader.uint(1).to_int()
      let base = 1UL << (10 + (w >> 3))
      let window = base + base / 8UL * (w & 7).to_uint64()
      if window > limit.to_uint64() {
        raise InvalidBinary(start, "Zstandard window exceeds budget")
      }
    }
    let dict_width = [0, 1, 2, 4][descriptor & 3]
    if dict_width > 0 && reader.uint(dict_width) != 0UL {
      raise InvalidBinary(start, "External Zstandard dictionary required")
    }
    let size_flag = descriptor >> 6
    let size_width = if size_flag == 0 {
      if single {
        1
      } else {
        0
      }
    } else {
      [0, 2, 4, 8][size_flag]
    }
    if size_width > 0 {
      let size = reader.uint(size_width) +
        (if size_flag == 1 { 256UL } else { 0UL })
      if size > (expected - output.length()).to_uint64() {
        raise InvalidBinary(
          start, "Zstandard content size exceeds output budget",
        )
      }
    }
    while true {
      let header = reader.uint(3).to_int()
      let kind = (header >> 1) & 3
      let size = header >> 3
      if kind == 3 || size > 131072 {
        raise InvalidBinary(reader.pos, "Invalid Zstandard block")
      }
      reader.take(if kind == 1 { 1 } else { size }) |> ignore
      if (header & 1) != 0 {
        break
      }
    }
    if (descriptor & 4) != 0 {
      reader.take(4) |> ignore
    }
    let inflater = @zstd.Inflater::new()
    inflater.src(input[start:reader.pos])
    let mut done = false
    while !done {
      match inflater.decode() {
        Data(bytes) => {
          if bytes.length() > expected - output.length() {
            raise InvalidBinary(start, "Zstandard output exceeds expected size")
          }
          output.write_bytes(bytes)
        }
        End => done = true
        Await => raise InvalidBinary(reader.pos, "Truncated Zstandard frame")
        Error(error) => raise error
      }
    }
  }
  if output.length() != expected {
    raise InvalidBinary(reader.pos, "Zstandard decoded size mismatch")
  }
  output.to_bytes()
}
