///|
fn kv3_binary_pack(value : KV3BinaryValue, depth : Int32) -> Json raise {
  if depth > 128 {
    raise InvalidBinary(0, "Binary KV3 JSON exceeds depth")
  }
  match value {
    BNull => Json::object({ "type": Json::string("null") })
    BBool(b) =>
      Json::object({ "type": Json::string("bool"), "value": Json::boolean(b) })
    BNumber(tag, bits) =>
      Json::object({
        "type": Json::string("number"),
        "storage": Json::number(tag.to_double()),
        "bits": Json::string(bits.to_string()),
      })
    BString(s) =>
      Json::object({ "type": Json::string("string"), "value": Json::string(s) })
    BBlob(bytes) => {
      let hex = "0123456789abcdef".to_array()
      let out = StringBuilder()
      for byte in bytes {
        let n = byte.to_int()
        out.write_char(hex[n / 16])
        out.write_char(hex[n % 16])
      }
      Json::object({
        "type": Json::string("blob"),
        "value": Json::string(out.to_string()),
      })
    }
    BArray(values) =>
      Json::object({
        "type": Json::string("array"),
        "value": Json::array(values.map(v => kv3_binary_pack(v, depth + 1))),
      })
    BObject(entries) =>
      Json::object({
        "type": Json::string("object"),
        "value": Json::array(
          entries.map(pair => {
            let (key, value) = pair
            Json::object({
              "key": Json::string(key),
              "value": kv3_binary_pack(value, depth + 1),
            })
          }),
        ),
      })
    BFlag(flag, value) =>
      Json::object({
        "type": Json::string("flag"),
        "flag": Json::string(flag),
        "value": kv3_binary_pack(value, depth + 1),
      })
  }
}

///|
pub fn kv3_binary_to_json(document : KV3BinaryDocument) -> Json raise {
  document.document() |> ignore
  Json::object({
    "version": Json::number(document.version.to_double()),
    "compression": Json::number(document.compression.to_double()),
    "format_id": Json::string(document.format_id),
    "root": kv3_binary_pack(document.root, 0),
  })
}

///|
fn kv3_binary_unpack(
  json : Json,
  depth : Int32,
  budget : Ref[Int32],
) -> KV3BinaryValue raise {
  budget.val += 1
  if depth > 128 || budget.val > 100000 {
    raise InvalidBinary(0, "Binary KV3 JSON exceeds budget")
  }
  guard json is Object(fields) && fields.get("type") is Some(String(kind)) else {
    raise InvalidBinary(0, "Expected typed binary KV3 JSON")
  }
  match kind {
    "null" if fields.length() == 1 => BNull
    "bool" if fields.length() == 2 && fields.get("value") is Some(True) =>
      BBool(true)
    "bool" if fields.length() == 2 && fields.get("value") is Some(False) =>
      BBool(false)
    "number" if fields.length() == 3 &&
      fields.get("storage") is Some(Number(n, ..)) &&
      n >= 0.0 &&
      n <= 27.0 &&
      n == n.to_int().to_double() &&
      fields.get("bits") is Some(String(bits)) =>
      BNumber(n.to_int(), @strconv.parse_uint64(bits[:]))
    "string" if fields.length() == 2 && fields.get("value") is Some(String(s)) =>
      BString(s)
    "blob" if fields.length() == 2 && fields.get("value") is Some(String(s)) => {
      let chars = s.to_array()
      if chars.length() % 2 != 0 || chars.length() > 33554432 {
        raise InvalidBinary(0, "Invalid blob hex length")
      }
      let out = @buffer.Buffer()
      for i in 0..<(chars.length() / 2) {
        guard kv3_hex(chars[i * 2]) is Some(a) &&
          kv3_hex(chars[i * 2 + 1]) is Some(b) else {
          raise InvalidBinary(0, "Invalid blob hexadecimal")
        }
        out.write_byte((a * 16 + b).to_byte())
      }
      BBlob(out.to_bytes())
    }
    "array" if fields.length() == 2 &&
      fields.get("value") is Some(Array(values)) =>
      BArray(values.map(v => kv3_binary_unpack(v, depth + 1, budget)))
    "object" if fields.length() == 2 &&
      fields.get("value") is Some(Array(entries)) =>
      BObject(
        entries.map(entry => {
          guard entry is Object(row) &&
            row.length() == 2 &&
            row.get("key") is Some(String(key)) &&
            row.get("value") is Some(value) else {
            raise InvalidBinary(0, "Invalid binary KV3 object member")
          }
          (key, kv3_binary_unpack(value, depth + 1, budget))
        }),
      )
    "flag" if fields.length() == 3 &&
      fields.get("flag") is Some(String(flag)) &&
      fields.get("value") is Some(value) =>
      BFlag(flag, kv3_binary_unpack(value, depth + 1, budget))
    _ => raise InvalidBinary(0, "Invalid binary KV3 JSON fields")
  }
}

///|
pub fn kv3_binary_from_json(json : Json) -> KV3BinaryDocument raise {
  guard json is Object(fields) &&
    fields.length() == 4 &&
    fields.get("version") is Some(Number(v, ..)) &&
    fields.get("compression") is Some(Number(c, ..)) &&
    fields.get("format_id") is Some(String(format_id)) &&
    fields.get("root") is Some(root) &&
    v >= 0.0 &&
    v <= 5.0 &&
    v == v.to_int().to_double() &&
    c >= 0.0 &&
    c <= 3.0 &&
    c == c.to_int().to_double() &&
    (c <= 2.0 || v == 0.0) else {
    raise InvalidBinary(0, "Invalid binary KV3 document JSON")
  }
  let result = KV3BinaryDocument::{
    version: v.to_int(),
    compression: c.to_int(),
    format_id,
    root: kv3_binary_unpack(root, 0, { val: 0, }),
  }
  result.document() |> ignore
  result
}
