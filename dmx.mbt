///|
/// DMX is a UUID-addressed graph, independently typed from KV1 and KV3.
/// Time uses 1/10000-second ticks; floating point components retain IEEE bits.
pub(all) enum DMXValue {
  DElement(String?)
  DInt(Int32)
  DFloatBits(UInt32)
  DBool(Bool)
  DString(String)
  DBinary(Bytes)
  DTime(Int32)
  DColor(UInt32)
  DVector(Int32, Array[UInt32])
  DArray(Int32, Array[DMXValue])
} derive(Eq, Debug)

///|
pub(all) struct DMXAttribute {
  name : String
  value : DMXValue
} derive(Eq, Debug)

///|
pub(all) struct DMXElement {
  id : String
  name : String
  kind : String
  attributes : Array[DMXAttribute]
} derive(Eq, Debug)

///|
pub(all) struct DMXDocument {
  format_name : String
  format_version : Int32
  root : String
  elements : Array[DMXElement]
} derive(Eq, Debug)

///|
pub extend DMXValue with Eq::{equal, not_equal}

///|
pub extend DMXValue with @debug.Debug::{to_repr}

///|
pub extend DMXAttribute with Eq::{equal, not_equal}

///|
pub extend DMXAttribute with @debug.Debug::{to_repr}

///|
pub extend DMXElement with Eq::{equal, not_equal}

///|
pub extend DMXElement with @debug.Debug::{to_repr}

///|
pub extend DMXDocument with Eq::{equal, not_equal}

///|
pub extend DMXDocument with @debug.Debug::{to_repr}

///|
fn dmx_uuid(text : String) -> String raise {
  kv3_bytes_guid(kv3_guid_bytes(text.to_lower()))
}

///|
fn dmx_types() -> Array[String] {
  [
    "", "element", "int", "float", "bool", "string", "binary", "time", "color", "vector2",
    "vector3", "vector4", "qangle", "quaternion", "vmatrix",
  ]
}

///|
fn dmx_type(value : DMXValue) -> Int32 {
  match value {
    DElement(_) => 1
    DInt(_) => 2
    DFloatBits(_) => 3
    DBool(_) => 4
    DString(_) => 5
    DBinary(_) => 6
    DTime(_) => 7
    DColor(_) => 8
    DVector(tag, _) | DArray(tag, _) => tag
  }
}

///|
fn dmx_string_check(
  text : String,
  options : BinaryOptions,
  total : Ref[Int32],
) -> Unit raise {
  let size = @utf8.encode(text[:]).length()
  if text.contains("\u0000") ||
    size > options.max_string_bytes ||
    size > options.max_bytes - total.val {
    raise InvalidBinary(0, "DMX string exceeds budget or contains NUL")
  }
  total.val += size
}

///|
fn dmx_value_check(
  value : DMXValue,
  options : BinaryOptions,
  total : Ref[Int32],
  nodes : Ref[Int32],
  array : Bool,
) -> Unit raise {
  nodes.val += 1
  if nodes.val > options.max_entries {
    raise InvalidBinary(0, "DMX attribute/value budget exceeded")
  }
  match value {
    DElement(Some(id)) =>
      if dmx_uuid(id) != id {
        raise InvalidBinary(0, "DMX UUIDs must be canonical lowercase")
      }
    DString(s) => dmx_string_check(s, options, total)
    DBinary(bytes) => {
      if bytes.length() > options.max_bytes - total.val {
        raise InvalidBinary(0, "DMX blob budget exceeded")
      }
      total.val += bytes.length()
    }
    DVector(tag, bits) => {
      if tag < 9 || tag > 14 || bits.length() != [2, 3, 4, 3, 4, 16][tag - 9] {
        raise InvalidBinary(0, "DMX vector type or dimension mismatch")
      }
      total.val += bits.length() * 4
    }
    DArray(tag, values) => {
      if array ||
        tag < 1 ||
        tag > 14 ||
        values.length() > options.max_entries - nodes.val {
        raise InvalidBinary(0, "Invalid DMX typed array")
      }
      for child in values {
        if child is DArray(_, _) || dmx_type(child) != tag {
          raise InvalidBinary(0, "DMX array element type mismatch")
        }
        dmx_value_check(child, options, total, nodes, true)
      }
    }
    _ => total.val += 4
  }
  if total.val > options.max_bytes {
    raise InvalidBinary(0, "DMX aggregate bytes exceeded")
  }
}

///|
fn dmx_validate(document : DMXDocument, options : BinaryOptions) -> Unit raise {
  check_binary_options(options)
  if document.format_name.is_empty() ||
    document.format_name.length() > 256 ||
    document.format_name
    .to_array()
    .any(c => {
      !((c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      localization_digit(c) ||
      ['_', '-', '.'].contains(c))
    }) ||
    document.format_version < 0 ||
    document.elements.is_empty() ||
    document.elements.length() > options.max_entries {
    raise InvalidBinary(0, "Invalid DMX document metadata")
  }
  let ids : Map[String, Bool] = Map([])
  let total : Ref[Int32] = { val: 0, }
  let nodes : Ref[Int32] = { val: 0, }
  for element in document.elements {
    if dmx_uuid(element.id) != element.id ||
      ids.contains(element.id) ||
      element.kind.is_empty() {
      raise InvalidBinary(0, "Duplicate/invalid DMX element identity")
    }
    ids[element.id] = true
    dmx_string_check(element.name, options, total)
    dmx_string_check(element.kind, options, total)
    let names : Map[String, Bool] = Map([])
    for attribute in element.attributes {
      let name = attribute.name.to_lower()
      if name.is_empty() || name == "name" || names.contains(name) {
        raise InvalidBinary(0, "Duplicate/reserved DMX attribute name")
      }
      names[name] = true
      dmx_string_check(attribute.name, options, total)
      dmx_value_check(attribute.value, options, total, nodes, false)
    }
  }
  if !ids.contains(document.root) {
    raise InvalidBinary(0, "DMX root UUID is not defined")
  }
}

///|
pub fn DMXDocument::element(self : DMXDocument, id : String) -> DMXElement? {
  for element in self.elements {
    if element.id == id.to_lower() {
      return Some(element)
    }
  }
  None
}

///|
fn dmx_references(value : DMXValue, ids : Map[String, Bool]) -> Unit {
  match value {
    DElement(Some(id)) => ids[id] = true
    DArray(_, values) =>
      for child in values {
        dmx_references(child, ids)
      }
    _ => ()
  }
}

///|
pub fn DMXDocument::external_references(
  self : DMXDocument,
) -> Array[String] raise {
  dmx_validate(self, BinaryOptions::default())
  let ids : Map[String, Bool] = Map([])
  for element in self.elements {
    for attribute in element.attributes {
      dmx_references(attribute.value, ids)
    }
  }
  for element in self.elements {
    ids.remove(element.id) |> ignore
  }
  let result = ids.keys().collect()
  result.sort_by((a, b) => a.lexical_compare(b))
  result
}

///|
pub fn DMXDocument::with_attribute(
  self : DMXDocument,
  id : String,
  name : String,
  value : DMXValue,
) -> DMXDocument raise {
  dmx_validate(self, BinaryOptions::default())
  let id = dmx_uuid(id)
  if self.element(id) is None {
    raise InvalidEdit("DMX element UUID was not found")
  }
  let elements = self.elements.map(element => {
    if element.id != id {
      return element
    }
    let attributes = element.attributes.copy()
    let mut found = false
    for i in 0..<attributes.length() {
      if attributes[i].name.to_lower() == name.to_lower() {
        attributes[i] = { name: attributes[i].name, value, }
        found = true
        break
      }
    }
    if !found {
      attributes.push({ name, value, })
    }
    { ..element, attributes, }
  })
  let document = { ..self, elements, }
  dmx_validate(document, BinaryOptions::default())
  document
}
