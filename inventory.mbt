///|
pub(all) struct InventoryRecord {
  library : String
  manifest : String
  app : SteamApp
} derive(Eq, Debug)

///|
pub(all) struct InventoryIssue {
  code : String
  library : String
  manifest : String?
  message : String
} derive(Eq, Debug)

///|
pub(all) struct InventoryTotal {
  known_size_bytes : Int64
  unknown_size_count : Int32
} derive(Eq, Debug)

///|
pub extend InventoryRecord with Eq::{equal, not_equal}

///|
pub extend InventoryRecord with @debug.Debug::{to_repr}

///|
pub extend InventoryIssue with Eq::{equal, not_equal}

///|
pub extend InventoryIssue with @debug.Debug::{to_repr}

///|
pub extend InventoryTotal with Eq::{equal, not_equal}

///|
pub extend InventoryTotal with @debug.Debug::{to_repr}

///|
/// Filter by Unicode lowercase name or identifier; sort by name, id or descending
/// size. Missing sizes sort last. Identifiers are compared as decimal integers.
pub fn select_inventory(
  records : Array[InventoryRecord],
  filter~ : String = "",
  sort~ : String = "id",
) -> Array[InventoryRecord] raise SteamError {
  if sort != "id" && sort != "name" && sort != "size" {
    raise InvalidManifest("Unknown inventory sort")
  }
  let needle = filter.to_lower()
  let result = records.filter(r => {
    r.app.name.to_lower().contains(needle) || r.app.app_id.contains(needle)
  })
  result.sort_by((a, b) => {
    let primary = match sort {
      "name" => a.app.name.to_lower().compare(b.app.name.to_lower())
      "size" =>
        match (a.app.size_on_disk, b.app.size_on_disk) {
          (Some(x), Some(y)) => y.compare(x)
          (Some(_), None) => -1
          (None, Some(_)) => 1
          _ => 0
        }
      _ => 0
    }
    if primary != 0 {
      primary
    } else {
      let by_id = decimal_compare(a.app.app_id, b.app.app_id)
      if by_id != 0 {
        by_id
      } else {
        let by_library = a.library.compare(b.library)
        if by_library != 0 {
          by_library
        } else {
          a.manifest.compare(b.manifest)
        }
      }
    }
  })
  result
}

///|
fn decimal_compare(a : String, b : String) -> Int32 {
  let x = a.trim_start(chars="0").to_owned()
  let y = b.trim_start(chars="0").to_owned()
  let length = x.length().compare(y.length())
  if length != 0 {
    length
  } else {
    x.compare(y)
  }
}

///|
pub fn inventory_total(
  records : Array[InventoryRecord],
) -> InventoryTotal raise SteamError {
  let mut known = 0L
  let mut unknown = 0
  for record in records {
    match record.app.size_on_disk {
      Some(size) => {
        if size < 0 || size > 9223372036854775807L - known {
          raise InvalidManifest("Inventory size total exceeds Int64 range")
        }
        known += size
      }
      None => unknown += 1
    }
  }
  { known_size_bytes: known, unknown_size_count: unknown, }
}

///|
/// Check listed records against declared apps. Paths are compared exactly;
/// filesystem canonicalization and case rules belong to the host adapter.
pub fn check_inventory(
  libraries : Array[SteamLibrary],
  records : Array[InventoryRecord],
) -> Array[InventoryIssue] {
  let issues : Array[InventoryIssue] = []
  let paths : Map[String, Bool] = Map([])
  let ids : Map[String, Bool] = Map([])
  let present : Map[(String, String), Bool] = Map([])
  for record in records {
    let name = record.manifest
      .replace_all(old="\\", new="/")
      .split("/")
      .last()
      .unwrap()
      .to_owned()
    if name != "appmanifest_" + record.app.app_id + ".acf" {
      issues.push({
        code: "appid_mismatch",
        library: record.library,
        manifest: Some(record.manifest),
        message: "Manifest filename does not match AppState appid",
      })
    }
    if ids.contains(record.app.app_id) {
      issues.push({
        code: "duplicate_app",
        library: record.library,
        manifest: Some(record.manifest),
        message: "App identifier occurs in multiple manifests: " +
        record.app.app_id,
      })
    }
    ids[record.app.app_id] = true
    present[(record.library, record.app.app_id)] = true
  }
  for library in libraries {
    if paths.contains(library.path) {
      issues.push({
        code: "duplicate_library",
        library: library.path,
        manifest: None,
        message: "Library path occurs more than once",
      })
      continue
    }
    paths[library.path] = true
    for id in library.app_ids {
      if !present.contains((library.path, id)) {
        issues.push({
          code: "missing_manifest",
          library: library.path,
          manifest: None,
          message: "Declared app has no readable manifest: " + id,
        })
      }
    }
  }
  issues
}

///|
/// RFC 4180 quoting with CRLF records. All fields are quoted, so commas,
/// quotes and embedded line breaks remain unambiguous.
pub fn inventory_csv(records : Array[InventoryRecord]) -> String {
  let builder = StringBuilder()
  builder.write_string(
    "\"app_id\",\"name\",\"install_dir\",\"size_on_disk\",\"build_id\",\"library\",\"manifest\"\r\n",
  )
  for record in records {
    let app = record.app
    let fields = [
      app.app_id,
      app.name,
      app.install_dir,
      match app.size_on_disk {
        Some(n) => n.to_string()
        None => ""
      },
      app.build_id.unwrap_or(""),
      record.library,
      record.manifest,
    ]
    for i in 0..<fields.length() {
      if i > 0 {
        builder.write_string(",")
      }
      builder.write_string("\"")
      builder.write_string(fields[i].replace_all(old="\"", new="\"\""))
      builder.write_string("\"")
    }
    builder.write_string("\r\n")
  }
  builder.to_string()
}
