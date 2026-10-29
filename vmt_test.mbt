///|
test "VMT Patch inheritance replace insert deletion proxies and provenance" {
  let sources : Map[String, String] = {
    "materials/base.vmt": "VertexLitGeneric { $BaseTexture moon/base $bumpmap moon/normal $alpha 1 Proxies { AnimatedTexture { animatedTextureVar $basetexture } } }",
    "materials/middle.vmt": "Patch { include materials/base.vmt insert { $basetexture moon/middle $detail moon/detail } replace { $alpha 0.5 $missing ignored } }",
    "materials/final.vmt": "Patch { include materials/middle.vmt insert { $bumpmap \"\" Proxies { TextureScroll { rate 1 } } } replace { $basetexture moon/final } }",
  }
  let material = @moonvalve.load_vmt("materials/final.vmt", p => sources[p])
  assert_eq(material.shader, "VertexLitGeneric")
  let doc : @moonvalve.Document = { entries: material.parameters, }
  assert_eq(doc.get("$BaseTexture"), Some(@moonvalve.Text("moon/final")))
  assert_eq(doc.get("$alpha"), Some(@moonvalve.Text("0.5")))
  assert_eq(doc.get("$bumpmap"), None)
  assert_eq(doc.get("$missing"), None)
  assert_eq(doc.get("Proxies").unwrap().as_object().unwrap().length(), 2)
  assert_eq(material.includes, ["materials/middle.vmt", "materials/base.vmt"])
  assert_true(
    material.origins.any(o => {
      o.source == "materials/final.vmt" && o.operation == "replace"
    }),
  )
  assert_eq(material.textures().map(t => t.target), [
    Some("materials/moon/final.vtf"),
    Some("materials/moon/detail.vtf"),
  ])
  assert_true(
    material
    .with_parameter("$detail", "moon/new")
    .stringify()
    .contains("moon/new"),
  )
}

///|
test "VMT cycles malformed patches dynamic and builtin textures" {
  assert_true(
    try {
      @moonvalve.load_vmt("materials/a.vmt", _ => {
        "Patch { include materials/a.vmt }"
      })
      |> ignore
      false
    } catch {
      _ => true
    },
  )
  for
    source in [
      "Patch { insert {x y} }", "Patch { include ../outside }", "Patch { include materials/base.vmt unknown {} }",
    ] {
    assert_true(
      try {
        @moonvalve.load_vmt("materials/a.vmt", p => {
          if p == "materials/a.vmt" {
            source
          } else {
            "UnlitGeneric {}"
          }
        })
        |> ignore
        false
      } catch {
        _ => true
      },
    )
  }
  let material = @moonvalve.parse_vmt(
    "UnlitGeneric {$envmap env_cubemap $basetexture _rt_FullFrameFB $detail \"$runtime\"}",
  )
  assert_eq(material.textures().map(t => t.status), [
    "builtin", "builtin", "dynamic",
  ])
}
