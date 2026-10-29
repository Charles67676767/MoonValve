///|
test "VPK deterministic create preload and lazy range loading" {
  let files : Map[String, Bytes] = {
    "materials/moon.vmt": b"VertexLitGeneric {}",
    "readme": b"hello",
    "empty.txt": b"",
    "配置/中文.txt": b"utf8",
  }
  for preload_bytes in [0, 3, 65535] {
    let bytes = @moonvalve.create_vpk(files, preload_bytes~)
    assert_eq(bytes, @moonvalve.create_vpk(files, preload_bytes~))
    let archive = @moonvalve.read_vpk(bytes)
    assert_eq(archive.version(), 1)
    assert_eq(archive.entries().length(), files.length())
    for (name, expected) in files {
      assert_eq(
        archive.read(name, (_, _, _) => fail("Unexpected external read")),
        expected,
      )
    }
    let tree_size = bytes[8].to_int() +
      (bytes[9].to_int() << 8) +
      (bytes[10].to_int() << 16) +
      (bytes[11].to_int() << 24)
    let indexed = @moonvalve.read_vpk(bytes[:12 + tree_size].to_owned())
    for (name, expected) in files {
      assert_eq(
        indexed.read(name, (archive, offset, count) => {
          assert_eq(archive, 32767)
          bytes[offset:offset + count].to_owned()
        }),
        expected,
      )
    }
    assert_eq(
      archive.find("MATERIALS\\MOON.VMT").unwrap().path,
      "materials/moon.vmt",
    )
  }
}

///|
test "VPK CRC corruption unsafe paths duplicates truncation and range mismatch" {
  for
    files in [
      { "../bad.txt": b"x" },
      { "a.txt": b"x", "A.txt": b"y" },
      { "C:/bad": b"x" },
    ] {
    assert_true(
      try {
        @moonvalve.create_vpk(files) |> ignore
        false
      } catch {
        _ => true
      },
    )
  }
  let bytes = @moonvalve.create_vpk({ "a.txt": b"hello" })
  for cut in [0, 4, 11, 20, bytes.length() - 6] {
    assert_true(
      try {
        @moonvalve.read_vpk(bytes[:cut].to_owned()) |> ignore
        false
      } catch {
        _ => true
      },
    )
  }
  let corrupt = bytes.to_array()
  corrupt[corrupt.length() - 1] = b'X'
  assert_true(
    try {
      @moonvalve.read_vpk(Bytes::from_array(corrupt)).read("a.txt", (_, _, _) => {
        b""
      })
      |> ignore
      false
    } catch {
      _ => true
    },
  )
  let indexed = @moonvalve.read_vpk(bytes[:bytes.length() - 5].to_owned())
  assert_true(
    try {
      indexed.read("a.txt", (_, _, _) => b"hi") |> ignore
      false
    } catch {
      _ => true
    },
  )
}

///|
test "mounted filesystem precedence base provenance and exact gameinfo expansion" {
  let archive = @moonvalve.read_vpk(
    @moonvalve.create_vpk({ "materials/moon.vmt": b"base", "only.txt": b"only" }),
  )
  let fs = @moonvalve.mount_game_filesystem([
    @moonvalve.LooseMount("mod", false, path => path == "materials/moon.vmt", _ => {
      b"mod"
    }),
    @moonvalve.VPKMount("base", true, archive, (_, _, _) => {
      fail("Unexpected range read")
    }),
  ])
  assert_eq(fs.read("materials/moon.vmt").bytes, b"mod")
  assert_eq(fs.read("only.txt").base_game, true)
  let candidates = fs.locate("materials/moon.vmt")
  assert_eq(candidates.length(), 2)
  assert_eq(candidates[0].selected, true)
  assert_eq(candidates[1].selected, false)
  assert_true(
    try {
      fs.read("../outside") |> ignore
      false
    } catch {
      _ => true
    },
  )
  let document = @moonvalve.parse(
    "GameInfo { FileSystem { SearchPaths { Game+Mod |gameinfo_path|. Game |all_source_engine_paths|hl2 Game custom/* Game |gameinfo_path|resource/|language| } } }",
  )
  let paths = @moonvalve.gameinfo_search_paths(
    document,
    "game/mod",
    "game",
    language="schinese",
  )
  assert_eq(paths.map(p => p.directory), [
    "game/mod", "game/hl2", "game/custom", "game/mod/resource/schinese",
  ])
  assert_eq(paths[0].ids, ["game", "mod"])
  assert_eq(paths[2].wildcard, true)
}
