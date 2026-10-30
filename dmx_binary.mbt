///|
priv struct DMXBinaryReader {
  input : ValveBytes
  strings : Array[String]
  elements : Array[DMXElement]
  options : BinaryOptions
  width : Int32
  mut nodes : Int32
}

///|
fn DMXBinaryReader::string(self : DMXBinaryReader) -> String raise {
  let index = self.input.uint(self.width)
  if index >= self.strings.length().to_uint64() {
    raise InvalidBinary(self.input.pos, "DMX string table index out of range")
  }
  self.strings[index.to_int()]
}

///|
fn DMXBinaryReader::value(
  self : DMXBinaryReader,
  tag : Int32,
  array : Bool,
) -> DMXValue raise {
  self.nodes += 1
  if self.nodes > self.options.max_entries {
    raise InvalidBinary(self.input.pos, "DMX value budget exceeded")
  }
  match tag {
    1 => {
      let index = self.input.uint(4)
      if index == 0xffffffffUL {
        DElement(None)
      } else if index == 0xfffffffeUL {
        DElement(Some(dmx_uuid(self.input.cstring(36))))
      } else {
        if index >= self.elements.length().to_uint64() {
          raise InvalidBinary(self.input.pos, "DMX element index out of range")
        }
        DElement(Some(self.elements[index.to_int()].id))
      }
    }
    2 => DInt(self.input.uint(4).to_uint().reinterpret_as_int())
    3 => DFloatBits(self.input.uint(4).to_uint())
    4 => {
      let n = self.input.uint(1)
      if n > 1UL {
        raise InvalidBinary(self.input.pos, "Invalid DMX bool")
      }
      DBool(n != 0UL)
    }
    5 =>
      DString(
        if array {
          self.input.cstring(self.options.max_string_bytes)
        } else {
          self.string()
        },
      )
    6 => DBinary(self.input.take(self.input.count(self.options.max_bytes)))
    7 => DTime(self.input.uint(4).to_uint().reinterpret_as_int())
    8 => DColor(self.input.uint(4).to_uint())
    9..<=14 =>
      DVector(
        tag,
        Array::makei([2, 3, 4, 3, 4, 16][tag - 9], _ => {
          self.input.uint(4).to_uint()
        }),
      )
    _ => raise InvalidBinary(self.input.pos, "Unsupported DMX type")
  }
}

///|
fn dmx_read_binary(
  input : ValveBytes,
  version : Int32,
  format_name : String,
  format_version : Int32,
  options : BinaryOptions,
) -> DMXDocument raise {
  if version != 4 && version != 5 {
    raise InvalidBinary(input.pos, "Supported DMX binary versions are 4 and 5")
  }
  if input.take(2) != b"\n\x00" {
    raise InvalidBinary(input.pos, "Expected DMX binary newline and NUL")
  }
  let count = input.count(options.max_entries)
  let strings : Array[String] = []
  for _ in 0..<count {
    strings.push(input.cstring(options.max_string_bytes))
  }
  let context = DMXBinaryReader::{
    input,
    strings,
    elements: [],
    options,
    width: if version == 4 {
      2
    } else {
      4
    },
    nodes: 0,
  }
  let count = input.count(options.max_entries)
  for _ in 0..<count {
    let kind = context.string()
    let name = context.string()
    let id = kv3_bytes_guid(input.take(16))
    context.elements.push({ id, name, kind, attributes: [], })
  }
  for i in 0..<count {
    let attributes : Array[DMXAttribute] = []
    let count = input.count(options.max_entries - context.nodes)
    for _ in 0..<count {
      let name = context.string()
      let tag = input.uint(1).to_int()
      let value = if tag > 14 {
        let kind = tag - 14
        if kind > 14 {
          raise InvalidBinary(input.pos, "Unsupported DMX array type")
        }
        let length = input.count(options.max_entries - context.nodes)
        let values = Array::makei(length, _ => context.value(kind, true))
        DArray(kind, values)
      } else {
        context.value(tag, false)
      }
      attributes.push({ name, value, })
    }
    context.elements[i] = { ..context.elements[i], attributes, }
  }
  if input.remaining() != 0 || context.elements.is_empty() {
    raise InvalidBinary(input.pos, "Trailing or empty DMX binary data")
  }
  let document = {
    format_name,
    format_version,
    root: context.elements[0].id,
    elements: context.elements,
  }
  dmx_validate(document, options)
  document
}

///|
fn dmx_binary_value(
  output : @buffer.Buffer,
  value : DMXValue,
  elements : Map[String, Int32],
  strings : Map[String, Int32],
  width : Int32,
  array : Bool,
) -> Unit raise {
  match value {
    DElement(None) => valve_uint(output, 0xffffffffUL, 4)
    DElement(Some(id)) =>
      if elements.get(id) is Some(index) {
        valve_uint(output, index.to_uint64(), 4)
      } else {
        valve_uint(output, 0xfffffffeUL, 4)
        vpk_cstring(output, id)
      }
    DInt(n) | DTime(n) =>
      valve_uint(output, n.reinterpret_as_uint().to_uint64(), 4)
    DFloatBits(n) | DColor(n) => valve_uint(output, n.to_uint64(), 4)
    DBool(b) => valve_uint(output, if b { 1UL } else { 0UL }, 1)
    DString(s) =>
      if array {
        vpk_cstring(output, s)
      } else {
        valve_uint(output, strings[s].to_uint64(), width)
      }
    DBinary(bytes) => {
      valve_uint(output, bytes.length().to_uint64(), 4)
      output.write_bytes(bytes[:])
    }
    DVector(_, bits) =>
      for n in bits {
        valve_uint(output, n.to_uint64(), 4)
      }
    DArray(_, _) => raise InvalidBinary(0, "Nested DMX arrays are invalid")
  }
}

///|
pub fn encode_dmx_binary(
  document : DMXDocument,
  version~ : Int32 = 5,
  options~ : BinaryOptions = BinaryOptions::default(),
) -> Bytes raise {
  dmx_validate(document, options)
  if version != 4 && version != 5 {
    raise InvalidBinary(0, "DMX binary writer supports versions 4 and 5")
  }
  let names : Map[String, Int32] = Map([])
  names["name"] = 0
  let elements = [document.element(document.root).unwrap()] +
    document.elements.filter(e => e.id != document.root)
  let ids : Map[String, Int32] = Map([])
  for i in 0..<elements.length() {
    let element = elements[i]
    ids[element.id] = i
    names[element.kind] = 0
    names[element.name] = 0
    for attribute in element.attributes {
      names[attribute.name] = 0
      if attribute.value is DString(s) {
        names[s] = 0
      }
    }
  }
  let strings = names.keys().collect()
  strings.sort_by((a, b) => a.lexical_compare(b))
  let width = if version == 4 { 2 } else { 4 }
  if strings.length() > (if version == 4 { 32767 } else { options.max_entries }) {
    raise InvalidBinary(0, "DMX string dictionary exceeds version limits")
  }
  for i in 0..<strings.length() {
    names[strings[i]] = i
  }
  let output = @buffer.Buffer()
  let header = "<!-- dmx encoding binary " +
    version.to_string() +
    " format " +
    document.format_name +
    " " +
    document.format_version.to_string() +
    " -->\n\u0000"
  output.write_bytes(@utf8.encode(header[:])[:])
  valve_uint(output, strings.length().to_uint64(), 4)
  for s in strings {
    vpk_cstring(output, s)
  }
  valve_uint(output, elements.length().to_uint64(), 4)
  for element in elements {
    valve_uint(output, names[element.kind].to_uint64(), width)
    valve_uint(output, names[element.name].to_uint64(), width)
    output.write_bytes(kv3_guid_bytes(element.id)[:])
  }
  for element in elements {
    valve_uint(output, element.attributes.length().to_uint64(), 4)
    for attribute in element.attributes {
      valve_uint(output, names[attribute.name].to_uint64(), width)
      let tag = dmx_type(attribute.value)
      valve_uint(
        output,
        (tag + (if attribute.value is DArray(_, _) { 14 } else { 0 })).to_uint64(),
        1,
      )
      if attribute.value is DArray(_, values) {
        valve_uint(output, values.length().to_uint64(), 4)
        for value in values {
          dmx_binary_value(output, value, ids, names, width, true)
        }
      } else {
        dmx_binary_value(output, attribute.value, ids, names, width, false)
      }
      if output.length() > options.max_bytes {
        raise InvalidBinary(0, "DMX output exceeds byte budget")
      }
    }
  }
  if output.length() > options.max_bytes {
    raise InvalidBinary(0, "DMX output exceeds byte budget")
  }
  output.to_bytes()
}
