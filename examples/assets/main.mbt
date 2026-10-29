///|
fn main {
  try {
    let source = @valve.parse_kv3(
      "{texture=resource:\"materials/moon.vmat\" amount=18446744073709551615}",
      allow_headerless=true,
    )
    let binary = @valve.encode_kv3_binary(
      @valve.kv3_binary_from_document(source),
      compression=2,
    )
    let decoded = @valve.decode_kv3_binary(binary)
    let edited = decoded.edit_query(
      "/texture",
      @valve.KV3ReplacePrefix("materials/", "materials/custom/"),
    )
    println(
      "Binary KV3: " +
      edited.select("/**?flag=resource").length().to_string() +
      " resource reference",
    )
    let container = @valve.read_resource_container(
      @valve.encode_kv3_resource(edited),
    )
    assert_eq(container.data().root, edited.root)

    let files : Map[String, Bytes] = {
      "materials/moon.vmt": b"Patch {include materials/base.vmt replace {$basetexture moon/custom}}",
      "materials/base.vmt": b"UnlitGeneric {$basetexture moon/base}",
      "materials/moon/custom.vtf": b"custom texture bytes",
      "materials/moon/base.vtf": b"base texture bytes",
    }
    let archive = @valve.read_vpk(@valve.create_vpk(files, preload_bytes=3))
    let filesystem = @valve.mount_game_filesystem([
      @valve.VPKMount("mod", false, archive, (_, _, _) => {
        fail("Unexpected range loader call")
      }),
    ])
    let material = @valve.load_vmt("materials/moon.vmt", path => {
      @utf8.decode(filesystem.read(path).bytes[:])
    })
    assert_eq(material.textures()[0].target, Some("materials/moon/custom.vtf"))
    let graph = @valve.build_dependency_graph(
      ["materials/moon.vmt"],
      filesystem,
    )
    let packed = graph.export_vpk()
    println(
      "VMT dependencies: " +
      graph.files().length().to_string() +
      " files, VPK " +
      packed.length().to_string() +
      " bytes",
    )
    println(
      "ZIP closure: " + graph.export_zip().length().to_string() + " bytes",
    )

    let english : @valve.Localization = {
      language: "English",
      encoding: "utf16le",
      tokens: [{ name: "Moon_Hello", text: "Hello %s1", }],
    }
    let chinese : @valve.Localization = {
      ..english,
      language: "schinese",
      tokens: [{ name: "Moon_Hello", text: "你好 %s1", }],
    }
    let po = @valve.parse_po(english.to_po(translated=chinese).stringify())
    let imported = english.import_po(po, "schinese")
    assert_eq(imported.issues, [])
    assert_eq(
      @valve.read_localization(imported.document.write()).tokens,
      chinese.tokens,
    )
    println("Localization: PO contexts and UTF-16 translation verified")

    let text = "<!-- dmx encoding keyvalues2 1 format model 22 -->\n\"DmeRoot\" {\"id\" \"elementid\" \"11111111-2222-4333-8444-555555555555\" \"name\" \"string\" \"Moon\" \"self\" \"element\" \"11111111-2222-4333-8444-555555555555\"}"
    let dmx = @valve.read_dmx(@utf8.encode(text[:]))
    assert_eq(@valve.read_dmx(@valve.encode_dmx_binary(dmx)), dmx)
    assert_eq(@valve.dmx_from_json(@valve.dmx_to_json(dmx)), dmx)
    println("DMX: UUID cycle and typed binary graph verified")
  } catch {
    error => {
      println(error.to_string())
      abort("Asset example failed")
    }
  }
}
