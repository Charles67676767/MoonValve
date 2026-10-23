///|
/// Ordered typed JSON; numeric payloads use decimal strings, including raw
/// Float32 bits. No precision or NaN information is routed through JSON numbers.
pub fn binary_to_json(entries : Array[BinaryEntry]) -> Json {
  Json::array(
    entries.map(entry => {
      let (kind, value) = match entry.value {
        ObjectValue(children) => ("object", binary_to_json(children))
        StringValue(s) => ("string", Json::string(s))
        WideString(s) => ("wstring", Json::string(s))
        Int32Value(n) => ("int32", Json::string(n.to_string()))
        Float32Bits(n) => ("float32bits", Json::string(n.to_string()))
        Pointer32(n) => ("pointer32", Json::string(n.to_string()))
        Color32(n) => ("color32", Json::string(n.to_string()))
        UInt64Value(n) => ("uint64", Json::string(n.to_string()))
        Int64Value(n) => ("int64", Json::string(n.to_string()))
      }
      Json::object({
        "key": Json::string(entry.key),
        "type": Json::string(kind),
        "value": value,
      })
    }),
  )
}

///|
pub fn binary_from_json(
  json : Json,
  options? : BinaryOptions = BinaryOptions::default(),
) -> Array[BinaryEntry] raise BinaryError {
  check_binary_options(options)
  let count : Ref[Int] = { val: 0, }
  let result = binary_json_entries(json, options, 0, count)
  encode_binary(result, options~) |> ignore
  result
}

///|
fn binary_json_entries(
  json : Json,
  options : BinaryOptions,
  depth : Int,
  count : Ref[Int],
) -> Array[BinaryEntry] raise BinaryError {
  guard json is Array(rows) else {
    raise InvalidBinary(0, "Expected a typed entry array")
  }
  if depth > options.max_depth {
    raise InvalidBinary(0, "JSON exceeds binary depth limit")
  }
  let result : Array[BinaryEntry] = []
  for row in rows {
    if count.val >= options.max_entries {
      raise InvalidBinary(0, "JSON exceeds binary entry limit")
    }
    count.val += 1
    guard row is Object(fields) &&
      fields.length() == 3 &&
      fields.get("key") is Some(String(key)) &&
      fields.get("type") is Some(String(kind)) &&
      fields.get("value") is Some(raw) else {
      raise InvalidBinary(0, "Expected key, type and value")
    }
    let value = if kind == "object" {
      ObjectValue(binary_json_entries(raw, options, depth + 1, count))
    } else {
      guard raw is String(text) else {
        raise InvalidBinary(0, "Scalar payload must be a string")
      }
      try {
        match kind {
          "string" => BinaryValue::StringValue(text)
          "wstring" => WideString(text)
          "int32" => Int32Value(@strconv.parse_int(text[:]))
          "int64" => Int64Value(@strconv.parse_int64(text[:]))
          "uint64" => UInt64Value(@strconv.parse_uint64(text[:]))
          "float32bits" => Float32Bits(@strconv.parse_uint(text[:]))
          "pointer32" => Pointer32(@strconv.parse_uint(text[:]))
          "color32" => Color32(@strconv.parse_uint(text[:]))
          _ => raise InvalidBinary(0, "Unknown typed JSON kind: " + kind)
        }
      } catch {
        _ => raise InvalidBinary(0, "Invalid typed JSON scalar: " + kind)
      }
    }
    result.push({ key, value, })
  }
  result
}
