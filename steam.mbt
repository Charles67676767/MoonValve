///|
/// A validated Steam app manifest. Decimal identifiers stay as strings.
pub(all) struct SteamApp {
  app_id : String
  name : String
  install_dir : String
  size_on_disk : Int64?
  build_id : String?
} derive(Eq, Debug)

///|
pub(all) struct SteamLibrary {
  index : String
  path : String
  label : String?
  app_ids : Array[String]
} derive(Eq, Debug)

///|
pub suberror SteamError {
  InvalidManifest(String)
} derive(Debug)

///|
fn steam_find(entries : Array[Entry], key : String) -> Value? {
  for entry in entries {
    if entry.key.equal_ignore_ascii_case(key) {
      return Some(entry.value)
    }
  }
  None
}

///|
fn steam_text(entries : Array[Entry], key : String) -> String? {
  match steam_find(entries, key) {
    Some(Text(s)) => Some(s)
    _ => None
  }
}

///|
fn decimal_id(text : String) -> Bool {
  !text.is_empty() && text.all(c => c >= '0' && c <= '9')
}

///|
/// Interpret an AppState object without touching the filesystem.
pub fn read_app_manifest(document : Document) -> SteamApp raise SteamError {
  guard steam_find(document.entries, "AppState") is Some(Object(entries)) else {
    raise InvalidManifest("Expected an AppState object")
  }
  guard steam_text(entries, "appid") is Some(app_id) && decimal_id(app_id) else {
    raise InvalidManifest("appid must be a nonempty decimal string")
  }
  guard steam_text(entries, "name") is Some(name) && !name.is_empty() else {
    raise InvalidManifest("name must be a nonempty string")
  }
  guard steam_text(entries, "installdir") is Some(install_dir) &&
    !install_dir.is_empty() else {
    raise InvalidManifest("installdir must be a nonempty string")
  }
  let size_on_disk = match steam_text(entries, "SizeOnDisk") {
    None => None
    Some(raw) => {
      if !decimal_id(raw) {
        raise InvalidManifest(
          "SizeOnDisk must be a nonnegative decimal integer",
        )
      }
      let value = @strconv.parse_int64(raw[:]) catch {
        _ => raise InvalidManifest("SizeOnDisk exceeds Int64 range")
      }
      Some(value)
    }
  }
  {
    app_id,
    name,
    install_dir,
    size_on_disk,
    build_id: steam_text(entries, "buildid"),
  }
}

///|
/// Read current object-style and legacy string-style libraryfolders entries.
pub fn read_library_folders(
  document : Document,
) -> Array[SteamLibrary] raise SteamError {
  guard steam_find(document.entries, "libraryfolders") is Some(Object(entries)) else {
    raise InvalidManifest("Expected a libraryfolders object")
  }
  let libraries : Array[SteamLibrary] = []
  for entry in entries {
    if !decimal_id(entry.key) {
      continue
    }
    match entry.value {
      Text(path) => {
        if path.is_empty() {
          raise InvalidManifest("Library path must not be empty")
        }
        libraries.push({ index: entry.key, path, label: None, app_ids: [], })
      }
      Object(fields) => {
        guard steam_text(fields, "path") is Some(path) && !path.is_empty() else {
          raise InvalidManifest("Library entry is missing its path")
        }
        let app_ids = match steam_find(fields, "apps") {
          Some(Object(apps)) =>
            apps.filter_map(e => {
              if decimal_id(e.key) {
                Some(e.key)
              } else {
                None
              }
            })
          None => []
          _ => raise InvalidManifest("Library apps must be an object")
        }
        libraries.push({
          index: entry.key,
          path,
          label: steam_text(fields, "label"),
          app_ids,
        })
      }
    }
  }
  libraries
}
