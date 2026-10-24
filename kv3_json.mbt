///|
fn kv3_pack(value : KV3Value) -> Json {
  let (kind, payload) = match value {
    KV3Null => ("null", Json::null())
    KV3Bool(b) => ("bool", Json::boolean(b))
    KV3Integer(s) => ("integer", Json::string(s))
    KV3Float(s) => ("float", Json::string(s))
    KV3String(s) => ("string", Json::string(s))
    KV3Blob(bytes) => {
      let output = StringBuilder()
      for byte in bytes {
        let digits = "0123456789abcdef"
        output.write_char(digits[byte.to_int() / 16].to_char().unwrap())
        output.write_char(digits[byte.to_int() % 16].to_char().unwrap())
      }
      ("blob", Json::string(output.to_string()))
    }
    KV3Array(values) => ("array", Json::array(values.map(kv3_pack)))
    KV3Object(entries) =>
      (
        "object",
        Json::array(
          entries.map(e => {
            Json::object({
              "key": Json::string(e.key),
              "value": kv3_pack(e.value),
            })
          }),
        ),
      )
    KV3Flag(flag, value) =>
      return Json::object({
        "type": Json::string("flag"),
        "flag": Json::string(flag),
        "value": kv3_pack(value),
      })
  }
  Json::object({ "type": Json::string(kind), "value": payload })
}

///|
/// Typed ordered JSON preserves integer precision, float spelling and flags.
pub fn kv3_to_json(document : KV3Document) -> Json raise {
  stringify_kv3(document) |> ignore
  Json::object({
    "header": match document.header {
      None => Json::null()
      Some(h) =>
        Json::object({
          "format_name": Json::string(h.format_name),
          "format_id": Json::string(h.format_id),
        })
    },
    "root": kv3_pack(document.root),
  })
}

///|
fn kv3_unpack(json : Json, depth : Int, count : Ref[Int]) -> KV3Value raise {
  count.val += 1
  if depth > 128 || count.val > 100000 {
    raise InvalidDocument("KV3 JSON exceeds resource limit")
  }
  guard json is Object(fields) &&
    fields.get("type") is Some(String(kind)) &&
    fields.get("value") is Some(value) else {
    raise InvalidDocument("Expected typed KV3 value")
  }
  if fields.length() != (if kind == "flag" { 3 } else { 2 }) {
    raise InvalidDocument("Unexpected typed KV3 fields")
  }
  match (kind, value) {
    ("null", Null) => KV3Null
    ("bool", True) => KV3Bool(true)
    ("bool", False) => KV3Bool(false)
    ("string", String(s)) => KV3String(s)
    ("integer", String(s)) => {
      guard kv3_number(s) is KV3Integer(_) else {
        raise InvalidDocument("Invalid typed integer")
      }
      KV3Integer(s)
    }
    ("float", String(s)) => {
      guard kv3_number(s) is KV3Float(_) else {
        raise InvalidDocument("Invalid typed float")
      }
      KV3Float(s)
    }
    ("blob", String(s)) => {
      let chars = s.to_array()
      if chars.length() % 2 != 0 || chars.length() > 2097152 {
        raise InvalidDocument("Invalid hexadecimal blob length")
      }
      let output = @buffer.Buffer()
      let mut i = 0
      while i < chars.length() {
        guard kv3_hex(chars[i]) is Some(a) && kv3_hex(chars[i + 1]) is Some(b) else {
          raise InvalidDocument("Invalid blob hex digit")
        }
        output.write_byte((a * 16 + b).to_byte())
        i += 2
      }
      KV3Blob(output.to_bytes())
    }
    ("array", Array(values)) =>
      KV3Array(values.map(v => kv3_unpack(v, depth + 1, count)))
    ("object", Array(rows)) =>
      KV3Object(
        rows.map(row => {
          guard row is Object(entry) &&
            entry.length() == 2 &&
            entry.get("key") is Some(String(key)) &&
            entry.get("value") is Some(value) else {
            raise InvalidDocument("Expected KV3 object entry")
          }
          { key, value: kv3_unpack(value, depth + 1, count), }
        }),
      )
    ("flag", _) => {
      guard fields.get("flag") is Some(String(flag)) && kv3_flag(flag) else {
        raise InvalidDocument("Unknown KV3 flag")
      }
      let inner = kv3_unpack(value, depth + 1, count)
      if inner is KV3Flag(_, _) {
        raise InvalidDocument("Stacked flags are not supported")
      }
      KV3Flag(flag.to_lower(), inner)
    }
    _ => raise InvalidDocument("KV3 type and payload do not match")
  }
}

///|
pub fn kv3_from_json(json : Json) -> KV3Document raise {
  guard json is Object(fields) &&
    fields.length() == 2 &&
    fields.get("header") is Some(header) &&
    fields.get("root") is Some(root) else {
    raise InvalidDocument("Expected KV3 document JSON")
  }
  let header = match header {
    Null => None
    Object(h) if h.length() == 2 &&
      h.get("format_name") is Some(String(format_name)) &&
      h.get("format_id") is Some(String(format_id)) =>
      Some(KV3Header::{ format_name, format_id, })
    _ => raise InvalidDocument("Invalid KV3 JSON header")
  }
  let document = KV3Document::{
    header,
    root: kv3_unpack(root, 0, { val: 0, }),
  }
  stringify_kv3(document) |> ignore
  document
}
