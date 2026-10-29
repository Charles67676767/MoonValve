///|
test "dependency closure provenance reverse edges base exclusions and VPK export" {
  let files : Map[String, Bytes] = {
    "materials/moon.vmt": b"Patch {include materials/base.vmt replace {$basetexture moon/custom}}",
    "materials/base.vmt": b"UnlitGeneric {$basetexture moon/base $envmap env_cubemap}",
    "materials/moon/custom.vtf": b"custom",
    "materials/moon/base.vtf": b"base",
  }
  let fs = @moonvalve.mount_game_filesystem([
    @moonvalve.LooseMount(
      "mod",
      false,
      p => p == "materials/moon.vmt" || p == "materials/moon/custom.vtf",
      p => files[p],
    ),
    @moonvalve.LooseMount("base", true, p => files.contains(p), p => files[p]),
  ])
  let graph = @moonvalve.build_dependency_graph(["materials/moon.vmt"], fs)
  assert_eq(graph.files().length(), 4)
  assert_true(graph.edges().any(e => e.status == "base-game"))
  assert_eq(graph.dependents("materials/moon/base.vtf"), [
    "materials/base.vmt", "materials/moon.vmt",
  ])
  assert_eq(graph.export_files().length(), 2)
  assert_eq(graph.export_files(include_base=true).length(), 4)
  let packed = @moonvalve.read_vpk(graph.export_vpk())
  assert_eq(packed.entries().length(), 2)
  assert_eq(
    packed.read("materials/moon/custom.vtf", (_, _, _) => {
      fail("Unexpected range read")
    }),
    b"custom",
  )
  assert_eq(graph.export_zip()[:4].to_owned(), b"PK\x03\x04")
}

///|
test "dependency missing dynamic opaque references block strict export" {
  let files : Map[String, Bytes] = {
    "materials/moon.vmt": b"UnlitGeneric {$basetexture moon/missing $detail \"$dynamic\"}",
    "unknown.mdl": b"opaque",
  }
  let fs = @moonvalve.mount_game_filesystem([
    @moonvalve.LooseMount("mod", false, p => files.contains(p), p => files[p]),
  ])
  let graph = @moonvalve.build_dependency_graph(
    ["materials/moon.vmt", "unknown.mdl"],
    fs,
  )
  assert_eq(graph.edges().map(e => e.status), ["missing", "dynamic", "opaque"])
  assert_true(
    try {
      graph.export_files() |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_eq(graph.export_files(strict=false).length(), 2)
  assert_true(
    try {
      @moonvalve.build_dependency_graph(
        ["materials/moon.vmt"],
        fs,
        max_files=1,
        max_bytes=1,
      )
      |> ignore
      false
    } catch {
      _ => true
    },
  )
}

///|
test "binary ZIP exports reject portable device names and file directory collisions" {
  for
    files in [
      { "CON.txt": b"device" },
      { "a": b"file", "a/b.txt": b"child" },
      { "dir/trailing.": b"dot" },
      { "dir\\escape": b"separator" },
    ] {
    assert_true(
      try {
        @moonvalve.export_files_zip(files) |> ignore
        false
      } catch {
        _ => true
      },
    )
  }
}
