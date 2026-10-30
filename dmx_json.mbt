///|
fn dmx_pack(value : DMXValue) -> Json {
  let kind = dmx_types()[dmx_type(value)]
  let payload = match value {
    DElement(id) =>
      match id {
        Some(s) => Json::string(s)
        None => Json::null()
      }
    DInt(n) | DTime(n) => Json::number(n.to_double())
    DFloatBits(n) | DColor(n) => Json::string(n.to_string())
    DBool(b) => Json::boolean(b)
    DString(s) => Json::string(s)
    DBinary(bytes) =>
      kv3_pack(KV3Blob(bytes))
      |> json => {
        match json {
          Object(fields) => fields["value"]
          _ => Json::null()
        }
      }
    DVector(_, bits) => Json::array(bits.map(n => Json::string(n.to_string())))
    DArray(_, values) => Json::array(values.map(dmx_pack))
  }
  Json::object({
    "type": Json::string(
      kind + (if value is DArray(_, _) { "_array" } else { "" }),
    ),
    "value": payload,
  })
}

///|
pub fn dmx_to_json(document : DMXDocument) -> Json raise {
  dmx_validate(document, BinaryOptions::default())
  Json::object({
    "format_name": Json::string(document.format_name),
    "format_version": Json::number(document.format_version.to_double()),
    "root": Json::string(document.root),
    "elements": Json::array(
      document.elements.map(e => {
        Json::object({
          "id": Json::string(e.id),
          "name": Json::string(e.name),
          "type": Json::string(e.kind),
          "attributes": Json::array(
            e.attributes.map(a => {
              Json::object({
                "name": Json::string(a.name),
                "value": dmx_pack(a.value),
              })
            }),
          ),
        })
      }),
    ),
  })
}

///|
fn dmx_json_string(fields : Map[String, Json], key : String) -> String raise {
  guard fields.get(key) is Some(String(s)) else {
    raise InvalidDocument("Expected DMX JSON string: " + key)
  }
  s
}

///|
fn dmx_unpack(
  json : Json,
  in_array : Bool,
  budget : Ref[Int32],
) -> DMXValue raise {
  budget.val += 1
  if budget.val > 100000 {
    raise InvalidDocument("DMX JSON value budget exceeded")
  }
  guard json is Object(fields) &&
    fields.length() == 2 &&
    fields.get("value") is Some(payload) else {
    raise InvalidDocument("Invalid DMX typed JSON")
  }
  let kind = dmx_json_string(fields, "type")
  let array = kind.has_suffix("_array")
  let base = if array { kind[:kind.length() - 6].to_owned() } else { kind }
  let mut tag = 0
  let types = dmx_types()
  for i in 1..<types.length() {
    if types[i] == base {
      tag = i
      break
    }
  }
  if tag == 0 {
    raise InvalidDocument("Unknown DMX JSON type")
  }
  if array {
    guard !in_array && payload is Array(values) else {
      raise InvalidDocument("Nested or invalid DMX JSON array")
    }
    return DArray(tag, values.map(v => dmx_unpack(v, true, budget)))
  }
  match (tag, payload) {
    (1, Null) => DElement(None)
    (1, String(id)) => DElement(Some(dmx_uuid(id)))
    (2 | 7, Number(n, ..)) if n >= -2147483648.0 &&
      n <= 2147483647.0 &&
      n == n.to_int().to_double() =>
      if tag == 2 {
        DInt(n.to_int())
      } else {
        DTime(n.to_int())
      }
    (3 | 8, String(bits)) => {
      let n = @strconv.parse_uint(bits[:])
      if tag == 3 {
        DFloatBits(n)
      } else {
        DColor(n)
      }
    }
    (4, True) => DBool(true)
    (4, False) => DBool(false)
    (5, String(s)) => DString(s)
    (6, String(hex)) => dmx_scalar_text(6, hex)
    (9..<=14, Array(bits)) =>
      DVector(
        tag,
        bits.map(v => {
          guard v is String(s) else {
            raise InvalidDocument("DMX vector bits must be decimal strings")
          }
          @strconv.parse_uint(s[:])
        }),
      )
    _ => raise InvalidDocument("DMX JSON payload does not match its type")
  }
}

///|
pub fn dmx_from_json(json : Json) -> DMXDocument raise {
  guard json is Object(fields) &&
    fields.length() == 4 &&
    fields.get("format_version") is Some(Number(version, ..)) &&
    version >= 0.0 &&
    version <= 2147483647.0 &&
    version == version.to_int().to_double() &&
    fields.get("elements") is Some(Array(elements)) &&
    elements.length() <= 100000 else {
    raise InvalidDocument("Invalid DMX JSON document")
  }
  let budget : Ref[Int32] = { val: 0, }
  let document = DMXDocument::{
    format_name: dmx_json_string(fields, "format_name"),
    format_version: version.to_int(),
    root: dmx_json_string(fields, "root"),
    elements: elements.map(element => {
      guard element is Object(row) &&
        row.length() == 4 &&
        row.get("attributes") is Some(Array(attributes)) &&
        attributes.length() <= 100000 else {
        raise InvalidDocument("Invalid DMX JSON element")
      }
      DMXElement::{
        id: dmx_json_string(row, "id"),
        name: dmx_json_string(row, "name"),
        kind: dmx_json_string(row, "type"),
        attributes: attributes.map(attribute => {
          guard attribute is Object(a) &&
            a.length() == 2 &&
            a.get("value") is Some(value) else {
            raise InvalidDocument("Invalid DMX JSON attribute")
          }
          DMXAttribute::{
            name: dmx_json_string(a, "name"),
            value: dmx_unpack(value, false, budget),
          }
        }),
      }
    }),
  }
  dmx_validate(document, BinaryOptions::default())
  document
}
