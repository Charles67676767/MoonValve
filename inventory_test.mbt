///|
fn record(
  id : String,
  name : String,
  size : Int64?,
  library~ : String = "lib",
) -> @moonvalve.InventoryRecord {
  {
    library,
    manifest: "appmanifest_" + id + ".acf",
    app: {
      app_id: id,
      name,
      install_dir: "game",
      size_on_disk: size,
      build_id: None,
    },
  }
}

///|
test "inventory filters sorts numerically and sums exact sizes" {
  let rows = [
    record("10", "Zoo", None),
    record("2", "alpha", Some(9007199254740993L)),
    record("3", "ALPINE", Some(5L)),
  ]
  assert_eq(@moonvalve.select_inventory(rows).map(r => r.app.app_id), [
    "2", "3", "10",
  ])
  assert_eq(
    @moonvalve.select_inventory(rows, filter="alp", sort="name").map(r => {
      r.app.app_id
    }),
    ["2", "3"],
  )
  assert_eq(
    @moonvalve.select_inventory(rows, sort="size").map(r => r.app.app_id),
    ["2", "3", "10"],
  )
  assert_eq(@moonvalve.inventory_total(rows), {
    known_size_bytes: 9007199254740998L,
    unknown_size_count: 1,
  })
  try
    @moonvalve.inventory_total([
      record("1", "a", Some(9223372036854775807L)),
      record("2", "b", Some(1L)),
    ])
  catch {
    @moonvalve.InvalidManifest(_) => ()
  } noraise {
    _ => fail("Expected size overflow")
  }
}

///|
test "inventory identifies duplicate libraries apps mismatches and missing declarations" {
  let libraries : Array[@moonvalve.SteamLibrary] = [
    { index: "0", path: "lib", label: None, app_ids: ["1", "2"], },
    { index: "1", path: "lib", label: None, app_ids: [], },
  ]
  let bad = { ..record("1", "a", None), manifest: "appmanifest_9.acf", }
  let codes = @moonvalve.check_inventory(libraries, [
    bad,
    record("1", "a", None, library="other"),
  ]).map(i => i.code)
  assert_eq(codes, [
    "appid_mismatch", "duplicate_app", "missing_manifest", "duplicate_library",
  ])
  for
    code in [
      "appid_mismatch", "duplicate_app", "duplicate_library", "missing_manifest",
    ] {
    assert_true(codes.contains(code))
  }
  assert_eq(codes.length(), 4)
}

///|
test "CSV retains quotes commas newlines and missing sizes" {
  let csv = @moonvalve.inventory_csv([record("1", "a,\"b\"\nc", None)])
  assert_true(csv.contains("\"a,\"\"b\"\"\nc\""))
  assert_true(csv.has_suffix("\"appmanifest_1.acf\"\r\n"))
}
