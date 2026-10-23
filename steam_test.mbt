///|
test "read an app manifest with exact Int64 size" {
  let source =
    #|"AppState" {
    #|  "appid" "480"
    #|  "name" "Moon Harbor"
    #|  "installdir" "Moon Harbor"
    #|  "SizeOnDisk" "9007199254740993"
    #|  "buildid" "12345"
    #|}
  let doc = @moonvalve.parse(source)
  let app = @moonvalve.read_app_manifest(doc)
  assert_eq(app.app_id, "480")
  assert_eq(app.size_on_disk, Some(9007199254740993L))
  assert_eq(app.build_id, Some("12345"))
}

///|
test "read mixed current and legacy Steam library folders" {
  let source =
    #|"libraryfolders" {
    #| "TimeNextStatsReport" "0"
    #| "0" { "path" "D:\\SteamLibrary" "label" "Games" "apps" { "480" "100" "570" "200" } }
    #| "1" "/mnt/games"
    #|}
  let doc = @moonvalve.parse(source)
  let libraries = @moonvalve.read_library_folders(doc)
  assert_eq(libraries.length(), 2)
  assert_eq(libraries[0].path, "D:\\SteamLibrary")
  assert_eq(libraries[0].app_ids, ["480", "570"])
  assert_eq(libraries[1].path, "/mnt/games")
  assert_eq(libraries[1].app_ids, [])
}

///|
test "Steam field names are ASCII case insensitive" {
  let doc = @moonvalve.parse("appstate { APPID 480 NAME demo INSTALLDIR demo }")
  let app = @moonvalve.read_app_manifest(doc)
  assert_eq(app.name, "demo")
  assert_eq(app.size_on_disk, None)
}

///|
test "invalid or incomplete Steam manifests are rejected" {
  let cases = [
    "other {}", "AppState {}", "AppState { appid nope name demo installdir demo }",
    "AppState { appid 480 name demo }", "AppState { appid 480 name demo installdir demo SizeOnDisk -1 }",
    "AppState { appid 480 name demo installdir demo SizeOnDisk 9223372036854775808 }",
  ]
  for input in cases {
    let document = @moonvalve.parse(input)
    try @moonvalve.read_app_manifest(document) catch {
      @moonvalve.InvalidManifest(_) => ()
    } noraise {
      _ => fail("Expected invalid app manifest")
    }
  }
}

///|
test "invalid library folders are rejected" {
  for
    input in [
      "wrong {}", "libraryfolders { 0 {} }", "libraryfolders { 0 \"\" }", "libraryfolders { 0 { path demo apps bad } }",
    ] {
    let document = @moonvalve.parse(input)
    try @moonvalve.read_library_folders(document) catch {
      @moonvalve.InvalidManifest(_) => ()
    } noraise {
      _ => fail("Expected invalid library folders")
    }
  }
}
