///|
pub(all) struct ResourceBlock {
  kind : String
  offset : Int
  bytes : Bytes
} derive(Eq, Debug)

///|
pub(all) struct ResourceContainer {
  version : Int
  declared_size : Int
  blocks : Array[ResourceBlock]
  trailing : Bytes
} derive(Eq, Debug)

///|
pub(all) struct ResourceExternalReference {
  id : UInt64
  name : String
} derive(Eq, Debug)

///|
pub extend ResourceBlock with Eq::{equal, not_equal}

///|
pub extend ResourceBlock with @debug.Debug::{to_repr}

///|
pub extend ResourceContainer with Eq::{equal, not_equal}

///|
pub extend ResourceContainer with @debug.Debug::{to_repr}

///|
pub extend ResourceExternalReference with Eq::{equal, not_equal}

///|
pub extend ResourceExternalReference with @debug.Debug::{to_repr}

///|
/// Source 2 resource header version 12; block offsets address their own offset
/// fields. Payloads remain bounded slices; unknown blocks are exposed unchanged.
pub fn read_resource_container(
  bytes : Bytes,
  options? : BinaryOptions = BinaryOptions::default(),
) -> ResourceContainer raise {
  check_binary_options(options)
  if bytes.length() > options.max_bytes {
    raise InvalidBinary(0, "Resource exceeds byte budget")
  }
  let input = valve_bytes(bytes)
  let declared_size = input.count(bytes.length())
  if input.uint(2) != 12UL || declared_size < 16 {
    raise InvalidBinary(4, "Unsupported resource header")
  }
  let version = input.uint(2).to_int()
  let table = input.count(declared_size - 8) + 8
  let count = input.count(options.max_entries)
  if table < 16 || table > declared_size || count > (declared_size - table) / 12 {
    raise InvalidBinary(table, "Invalid resource block table")
  }
  input.pos = table
  let ranges : Array[(Int, Int)] = [(0, table + count * 12)]
  let blocks : Array[ResourceBlock] = []
  for _ in 0..<count {
    let kind_bytes = input.take(4)
    if kind_bytes.to_array().any(c => c < b'\x20' || c > b'\x7e') {
      raise InvalidBinary(input.pos, "Invalid resource block name")
    }
    let kind = @utf8.decode(kind_bytes[:])
    let base = input.pos
    let offset = input.count(declared_size - base) + base
    let size = input.count(declared_size - offset)
    for (start, end) in ranges {
      if size > 0 && offset < end && start < offset + size {
        raise InvalidBinary(offset, "Overlapping resource blocks")
      }
    }
    ranges.push((offset, offset + size))
    blocks.push({ kind, offset, bytes: bytes[offset:offset + size].to_owned(), })
  }
  {
    version,
    declared_size,
    blocks,
    trailing: bytes[declared_size:].to_owned(),
  }
}

///|
pub fn ResourceContainer::data(
  self : ResourceContainer,
  options? : BinaryOptions = BinaryOptions::default(),
) -> KV3BinaryDocument raise {
  let found = self.blocks.filter(b => b.kind == "DATA")
  if found.length() != 1 {
    raise InvalidBinary(0, "Expected exactly one DATA block")
  }
  decode_kv3_binary(found[0].bytes, options~)
}

///|
pub fn ResourceContainer::external_references(
  self : ResourceContainer,
  options? : BinaryOptions = BinaryOptions::default(),
) -> Array[ResourceExternalReference] raise {
  check_binary_options(options)
  if self.blocks.length() > options.max_entries {
    raise InvalidBinary(0, "Resource block count exceeds budget")
  }
  let mut total = 0
  for block in self.blocks {
    if block.bytes.length() > options.max_bytes - total {
      raise InvalidBinary(0, "Resource blocks exceed aggregate budget")
    }
    total += block.bytes.length()
  }
  let output : Array[ResourceExternalReference] = []
  for block in self.blocks {
    if block.kind != "RERL" {
      continue
    }
    let reader = valve_bytes(block.bytes)
    let table = reader.count(block.bytes.length())
    let count = reader.count(options.max_entries - output.length())
    if count == 0 {
      continue
    }
    if table < 8 || count > (block.bytes.length() - table) / 16 {
      raise InvalidBinary(table, "Invalid RERL table")
    }
    reader.pos = table
    for _ in 0..<count {
      let id = reader.uint(8)
      let base = reader.pos
      let relative = reader.uint(4).reinterpret_as_int64()
      let signed = if relative >= 2147483648L {
        relative - 4294967296L
      } else {
        relative
      }
      let absolute = base.to_int64() + signed
      reader.uint(4) |> ignore
      if absolute < (table + count * 16).to_int64() ||
        absolute >= block.bytes.length().to_int64() {
        raise InvalidBinary(base, "Invalid RERL string offset")
      }
      let name_reader = valve_bytes(block.bytes)
      name_reader.pos = absolute.to_int()
      output.push({ id, name: name_reader.cstring(options.max_string_bytes), })
    }
  }
  output
}

///|
/// Construct a DATA-only resource. Rebuilding arbitrary compiled resources
/// needs block-specific relocation and is deliberately a separate operation.
pub fn encode_kv3_resource(
  document : KV3BinaryDocument,
  resource_version? : Int = 1,
  version? : Int = 5,
  compression? : Int = 0,
  options? : BinaryOptions = BinaryOptions::default(),
) -> Bytes raise {
  if resource_version < 0 || resource_version > 65535 {
    raise InvalidBinary(0, "Resource version exceeds uint16")
  }
  let data = encode_kv3_binary(document, version~, compression~, options~)
  if data.length() > options.max_bytes - 28 {
    raise InvalidBinary(0, "Resource exceeds byte budget")
  }
  let output = @buffer.Buffer()
  valve_uint(output, (28 + data.length()).to_uint64(), 4)
  valve_uint(output, 12UL, 2)
  valve_uint(output, resource_version.to_uint64(), 2)
  valve_uint(output, 8UL, 4)
  valve_uint(output, 1UL, 4)
  output.write_bytes(b"DATA"[:])
  valve_uint(output, 8UL, 4)
  valve_uint(output, data.length().to_uint64(), 4)
  output.write_bytes(data[:])
  output.to_bytes()
}
