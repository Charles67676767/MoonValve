///|
/// Binary KV3 numbers retain their storage type and exact integer/IEEE bits.
/// Tag numbers follow Valve KV3: int64=3, uint64=4, double=5, int32=11,
/// uint32=12, float=19, int16=20, uint16=21, int8=22, uint8=23.
pub(all) enum KV3BinaryValue {
  BNull
  BBool(Bool)
  BNumber(Int, UInt64)
  BString(String)
  BBlob(Bytes)
  BArray(Array[KV3BinaryValue])
  BObject(Array[(String, KV3BinaryValue)])
  BFlag(String, KV3BinaryValue)
} derive(Eq, Debug)

///|
pub extend KV3BinaryValue with Eq::{equal, not_equal}

///|
pub extend KV3BinaryValue with @debug.Debug::{to_repr}

///|
pub(all) struct KV3BinaryDocument {
  version : Int
  compression : Int
  format_id : String
  root : KV3BinaryValue
} derive(Eq, Debug)

///|
pub extend KV3BinaryDocument with Eq::{equal, not_equal}

///|
pub extend KV3BinaryDocument with @debug.Debug::{to_repr}

///|
fn kv3_binary_width(tag : Int) -> Int raise BinaryError {
  match tag {
    3 | 4 | 5 => 8
    11 | 12 | 19 => 4
    20 | 21 => 2
    22 | 23 => 1
    _ => raise InvalidBinary(0, "Unknown KV3 number storage type")
  }
}

///|
fn kv3_binary_float(n : Double) -> String {
  if n.reinterpret_as_uint64() == 0x8000000000000000UL {
    return "-0.0"
  }
  if n.is_nan() {
    "nan"
  } else if n.is_inf() {
    if n < 0.0 {
      "-inf"
    } else {
      "inf"
    }
  } else {
    let text = n.to_string()
    if text.contains(".") || text.contains("e") || text.contains("E") {
      text
    } else {
      text + ".0"
    }
  }
}

///|
fn KV3BinaryValue::semantic(
  self : KV3BinaryValue,
  depth : Int,
  budget : Ref[Int],
) -> KV3Value raise {
  budget.val += 1
  if depth > 128 || budget.val > 100000 {
    raise InvalidBinary(0, "Binary KV3 tree exceeds budget")
  }
  match self {
    BNull => KV3Null
    BBool(b) => KV3Bool(b)
    BNumber(tag, bits) => {
      let width = kv3_binary_width(tag)
      if width < 8 && bits >= 1UL << (width * 8) {
        raise InvalidBinary(0, "Number bits exceed storage width")
      }
      match tag {
        5 => KV3Float(kv3_binary_float(bits.reinterpret_as_double()))
        19 =>
          KV3Float(
            kv3_binary_float(
              Float::reinterpret_from_uint(bits.to_uint()).to_double(),
            ),
          )
        3 => KV3Integer(bits.reinterpret_as_int64().to_string())
        11 => KV3Integer(bits.to_uint().reinterpret_as_int().to_string())
        20 | 22 => {
          let sign = 1 << (width * 8 - 1)
          let n = bits.to_int()
          KV3Integer((if n >= sign { n - sign * 2 } else { n }).to_string())
        }
        _ => KV3Integer(bits.to_string())
      }
    }
    BString(s) => KV3String(s)
    BBlob(b) => KV3Blob(b)
    BArray(values) => KV3Array(values.map(v => v.semantic(depth + 1, budget)))
    BObject(entries) => {
      let keys : Map[String, Bool] = Map([])
      KV3Object(
        entries.map(pair => {
          let (key, value) = pair
          if keys.contains(key) {
            raise InvalidBinary(0, "Duplicate binary KV3 field")
          }
          keys[key] = true
          KV3Entry::{ key, value: value.semantic(depth + 1, budget), }
        }),
      )
    }
    BFlag(flag, value) => {
      if !kv3_flag(flag) || value is BFlag(_, _) {
        raise InvalidBinary(0, "Invalid binary KV3 flag")
      }
      KV3Flag(flag, value.semantic(depth + 1, budget))
    }
  }
}

///|
pub fn KV3BinaryDocument::document(
  self : KV3BinaryDocument,
) -> KV3Document raise {
  let header = KV3Header::{
    format_name: if self.format_id == generic_kv3_header().format_id {
      "generic"
    } else {
      "binary"
    },
    format_id: self.format_id,
  }
  if !kv3_guid(header.format_id) {
    raise InvalidBinary(0, "Invalid KV3 format GUID")
  }
  { header: Some(header), root: self.root.semantic(0, { val: 0, }), }
}

///|
fn kv3_binary_from_value(value : KV3Value, depth : Int) -> KV3BinaryValue raise {
  if depth > 128 {
    raise InvalidBinary(0, "KV3 conversion exceeds depth")
  }
  match value {
    KV3Null => BNull
    KV3Bool(b) => BBool(b)
    KV3String(s) => BString(s)
    KV3Blob(b) => BBlob(b)
    KV3Integer(s) =>
      if s.has_prefix("-") {
        BNumber(3, @strconv.parse_int64(s[:]).reinterpret_as_uint64())
      } else {
        let digits = if s.has_prefix("+") { s[1:].to_owned() } else { s }
        BNumber(4, @strconv.parse_uint64(digits[:]))
      }
    KV3Float(s) => {
      let n = match s.to_lower() {
        "nan" => 0x7ff8000000000000UL.reinterpret_as_double()
        "inf" | "+inf" => 0x7ff0000000000000UL.reinterpret_as_double()
        "-inf" => 0xfff0000000000000UL.reinterpret_as_double()
        _ => @strconv.parse_double(s[:])
      }
      BNumber(5, n.reinterpret_as_uint64())
    }
    KV3Array(values) =>
      BArray(values.map(v => kv3_binary_from_value(v, depth + 1)))
    KV3Object(entries) =>
      BObject(
        entries.map(e => (e.key, kv3_binary_from_value(e.value, depth + 1))),
      )
    KV3Flag(flag, value) => BFlag(flag, kv3_binary_from_value(value, depth + 1))
  }
}

///|
pub fn kv3_binary_from_document(
  document : KV3Document,
) -> KV3BinaryDocument raise {
  stringify_kv3(document) |> ignore
  {
    version: 5,
    compression: 0,
    format_id: document.header.unwrap_or(generic_kv3_header()).format_id,
    root: kv3_binary_from_value(document.root, 0),
  }
}

///|
fn kv3_guid_bytes(id : String) -> Bytes raise BinaryError {
  if !kv3_guid(id) {
    raise InvalidBinary(0, "Invalid KV3 GUID")
  }
  let digits = id.replace_all(old="-", new="").to_array()
  let raw : Array[Byte] = []
  for i in 0..<16 {
    raw.push(
      (kv3_hex(digits[i * 2]).unwrap() * 16 +
      kv3_hex(digits[i * 2 + 1]).unwrap()).to_byte(),
    )
  }
  Bytes::from_array(
    [
      raw[3],
      raw[2],
      raw[1],
      raw[0],
      raw[5],
      raw[4],
      raw[7],
      raw[6],
      ..raw[8:].to_owned(),
    ],
  )
}

///|
fn kv3_bytes_guid(raw : Bytes) -> String raise BinaryError {
  if raw.length() != 16 {
    raise InvalidBinary(0, "Truncated GUID")
  }
  let chars = "0123456789abcdef".to_array()
  let out = StringBuilder()
  let order = [3, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15]
  for i in 0..<16 {
    if [4, 6, 8, 10].contains(i) {
      out.write_char('-')
    }
    let n = raw[order[i]].to_int()
    out.write_char(chars[n / 16])
    out.write_char(chars[n % 16])
  }
  out.to_string()
}
