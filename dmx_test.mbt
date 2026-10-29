///|
test "DMX binary 4 and 5 preserve typed arrays cycles shared stubs IEEE bits and Unicode" {
  let root = "11111111-2222-4333-8444-555555555555"
  let child = "66666666-7777-4888-8999-aaaaaaaaaaaa"
  let external = "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
  let scalars : Array[@moonvalve.DMXValue] = [
    @moonvalve.DElement(Some(child)),
    @moonvalve.DInt(-2147483648),
    @moonvalve.DFloatBits(0x7fc00001U),
    @moonvalve.DBool(true),
    @moonvalve.DString("中文😀"),
    @moonvalve.DBinary(b"\x00\xff"),
    @moonvalve.DTime(-12345),
    @moonvalve.DColor(0xff123456U),
  ]
  let attributes : Array[@moonvalve.DMXAttribute] = scalars.mapi((i, value) => {
    name: "attr" + i.to_string(),
    value,
  })
  for i in 0..<scalars.length() {
    attributes.push({
      name: "array" + i.to_string(),
      value: @moonvalve.DArray(i + 1, [scalars[i], scalars[i]]),
    })
  }
  for tag in 9..<=14 {
    let values = Array::makei([2, 3, 4, 3, 4, 16][tag - 9], i => {
      if i == 0 {
        0x80000000U
      } else {
        1.25F.reinterpret_as_uint()
      }
    })
    attributes.push({
      name: "vector" + tag.to_string(),
      value: @moonvalve.DVector(tag, values),
    })
    attributes.push({
      name: "vectors" + tag.to_string(),
      value: @moonvalve.DArray(tag, [@moonvalve.DVector(tag, values)]),
    })
  }
  attributes.push({
    name: "external",
    value: @moonvalve.DElement(Some(external)),
  })
  attributes.push({ name: "null", value: @moonvalve.DElement(None), })
  let document : @moonvalve.DMXDocument = {
    format_name: "model",
    format_version: 22,
    root,
    elements: [
      { id: root, name: "root", kind: "DmeRoot", attributes, },
      {
        id: child,
        name: "child",
        kind: "DmeChild",
        attributes: [
          { name: "parent", value: @moonvalve.DElement(Some(root)), },
        ],
      },
    ],
  }
  assert_eq(document.external_references(), [external])
  for version in [4, 5] {
    let bytes = @moonvalve.encode_dmx_binary(document, version~)
    let decoded = @moonvalve.read_dmx(bytes)
    assert_eq(decoded, document)
    assert_eq(@moonvalve.encode_dmx_binary(decoded, version~), bytes)
    for cut in [0, 5, 30, bytes.length() / 2, bytes.length() - 1] {
      assert_true(
        try {
          @moonvalve.read_dmx(bytes[:cut].to_owned()) |> ignore
          false
        } catch {
          _ => true
        },
      )
    }
  }
  let edited = document.with_attribute(root, "attr1", @moonvalve.DInt(7))
  assert_eq(edited.element(child), document.element(child))
  assert_eq(
    edited.element(root).unwrap().attributes[2].value,
    @moonvalve.DFloatBits(0x7fc00001U),
  )
}

///|
test "DMX KeyValues2 nested elements missing IDs forward references arrays and text normalization" {
  let text = "<!-- dmx encoding keyvalues2 1 format model 22 -->\n\"DmeRoot\" { \"name\" \"string\" \"root\" \"child\" \"DmeChild\" {\"name\" \"string\" \"inline\" \"n\" \"int\" \"-1\"} \"forward\" \"element\" \"11111111-2222-4333-8444-555555555555\" \"array\" \"element_array\" [\"element\" \"\", \"DmeChild\" {\"name\" \"string\" \"second\"},] \"vector\" \"vector3\" \"1 2 -0\" \"blob\" \"binary\" \"00 ff 12\" } \"DmeFinal\" {\"id\" \"elementid\" \"11111111-2222-4333-8444-555555555555\"}"
  let document = @moonvalve.read_dmx(@utf8.encode(text[:]))
  assert_eq(document.elements.length(), 4)
  assert_eq(document.external_references(), [])
  let canonical = @moonvalve.stringify_dmx(document)
  assert_eq(@moonvalve.read_dmx(@utf8.encode(canonical[:])), document)
  assert_eq(
    @moonvalve.read_dmx(@moonvalve.encode_dmx_binary(document)),
    document,
  )
}

///|
test "DMX rejects duplicate UUIDs wrong typed arrays unknown versions and dangling root" {
  let id = "11111111-2222-4333-8444-555555555555"
  let element : @moonvalve.DMXElement = {
    id,
    name: "root",
    kind: "DmeRoot",
    attributes: [],
  }
  let document : @moonvalve.DMXDocument = {
    format_name: "dmx",
    format_version: 1,
    root: id,
    elements: [element],
  }
  assert_true(
    try {
      @moonvalve.encode_dmx_binary({ ..document, elements: [element, element], })
      |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      @moonvalve.encode_dmx_binary(document, version=9) |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      document.with_attribute(
        id,
        "bad",
        @moonvalve.DArray(2, [@moonvalve.DBool(true)]),
      )
      |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      document.with_attribute(id, "bad", @moonvalve.DVector(10, [0U])) |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      @moonvalve.encode_dmx_binary({
        ..document,
        root: "00000000-0000-0000-0000-000000000000",
      })
      |> ignore
      false
    } catch {
      _ => true
    },
  )
}

///|
test "DMX writer rejects format names beyond the bounded header" {
  let id = "11111111-2222-4333-8444-555555555555"
  let doc : @moonvalve.DMXDocument = {
    format_name: String::make(257, 'x'),
    format_version: 1,
    root: id,
    elements: [{ id, name: "root", kind: "DmeRoot", attributes: [], }],
  }
  assert_true(
    try {
      @moonvalve.encode_dmx_binary(doc) |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      @moonvalve.stringify_dmx(doc) |> ignore
      false
    } catch {
      _ => true
    },
  )
}
