///|
pub(all) enum GameMount {
  LooseMount(String, Bool, (String) -> Bool raise, (String) -> Bytes raise)
  VPKMount(String, Bool, VPKArchive, (Int32, Int32, Int32) -> Bytes raise)
}

///|
pub(all) struct MountedFile {
  path : String
  mount : String
  base_game : Bool
  bytes : Bytes
} derive(Eq, Debug)

///|
pub(all) struct MountCandidate {
  mount : String
  base_game : Bool
  selected : Bool
} derive(Eq, Debug)

///|
pub extend MountedFile with Eq::{equal, not_equal}

///|
pub extend MountedFile with @debug.Debug::{to_repr}

///|
pub extend MountCandidate with Eq::{equal, not_equal}

///|
pub extend MountCandidate with @debug.Debug::{to_repr}

///|
struct GameFileSystem {
  mounts : Array[GameMount]
  max_bytes : Int32
}

///|
fn GameMount::identity(self : GameMount) -> (String, Bool) {
  match self {
    LooseMount(id, base, _, _) | VPKMount(id, base, _, _) => (id, base)
  }
}

///|
/// Mount order is search order: the first existing file wins. Host callbacks
/// provide explicit filesystem access; no directories are discovered implicitly.
pub fn mount_game_filesystem(
  mounts : Array[GameMount],
  max_bytes~ : Int32 = 16777216,
) -> GameFileSystem raise {
  if mounts.length() > 128 || max_bytes < 1 || max_bytes > 67108864 {
    raise InvalidReference("Invalid game filesystem budgets")
  }
  let names : Map[String, Bool] = Map([])
  for mount in mounts {
    let (name, _) = mount.identity()
    if name.is_empty() || names.contains(name) {
      raise InvalidReference("Mount identifiers must be unique and nonempty")
    }
    names[name] = true
  }
  { mounts: mounts.copy(), max_bytes, }
}

///|
fn game_virtual_path(path : String) -> String raise {
  let normalized = path.replace_all(old="\\", new="/")
  if !resource_relative(normalized) {
    raise InvalidReference("Expected a safe game-relative path")
  }
  normalized
}

///|
pub fn GameFileSystem::locate(
  self : GameFileSystem,
  path : String,
) -> Array[MountCandidate] raise {
  let path = game_virtual_path(path)
  let output : Array[MountCandidate] = []
  for mount in self.mounts {
    let exists = match mount {
      LooseMount(_, _, exists, _) => exists(path)
      VPKMount(_, _, archive, _) => archive.find(path) is Some(_)
    }
    if exists {
      let (id, base) = mount.identity()
      output.push({ mount: id, base_game: base, selected: output.is_empty(), })
    }
  }
  output
}

///|
pub fn GameFileSystem::read(
  self : GameFileSystem,
  path : String,
) -> MountedFile raise {
  let path = game_virtual_path(path)
  for mount in self.mounts {
    let bytes = match mount {
      LooseMount(_, _, exists, read) =>
        if exists(path) {
          Some(read(path))
        } else {
          None
        }
      VPKMount(_, _, archive, loader) =>
        if archive.find(path) is Some(_) {
          Some(archive.read(path, loader))
        } else {
          None
        }
    }
    if bytes is Some(bytes) {
      if bytes.length() > self.max_bytes {
        raise InvalidReference("Mounted file exceeds byte budget")
      }
      let (id, base_game) = mount.identity()
      return { path, mount: id, base_game, bytes, }
    }
  }
  raise InvalidReference("Game file was not found: " + path)
}

///|
pub(all) struct GameSearchPath {
  ids : Array[String]
  directory : String
  wildcard : Bool
} derive(Eq, Debug)

///|
pub extend GameSearchPath with Eq::{equal, not_equal}

///|
pub extend GameSearchPath with @debug.Debug::{to_repr}

///|
fn game_child(entries : Array[Entry], key : String) -> Value? {
  for entry in entries {
    if entry.key.to_lower() == key.to_lower() {
      return Some(entry.value)
    }
  }
  None
}

///|
/// Expand known gameinfo tokens using explicit roots. Wildcard paths are plans
/// for the caller to enumerate and mount, not permission to scan the host disk.
pub fn gameinfo_search_paths(
  document : Document,
  gameinfo_directory : String,
  engine_directory : String,
  language~ : String = "english",
) -> Array[GameSearchPath] raise {
  if gameinfo_directory.is_empty() ||
    engine_directory.is_empty() ||
    language.is_empty() ||
    language
    .to_array()
    .any(c => !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_')) {
    raise InvalidReference("Invalid explicit gameinfo roots or language")
  }
  guard game_child(document.entries, "GameInfo") is Some(Object(info)) &&
    game_child(info, "FileSystem") is Some(Object(filesystem)) &&
    game_child(filesystem, "SearchPaths") is Some(Object(paths)) else {
    raise InvalidReference("GameInfo/FileSystem/SearchPaths was not found")
  }
  if paths.length() > 128 {
    raise InvalidReference("Gameinfo search path budget exceeded")
  }
  let output : Array[GameSearchPath] = []
  for entry in paths {
    guard entry.value is Text(raw) else {
      raise InvalidReference("Search paths must be strings")
    }
    let ids = entry.key.split("+").map(x => x.to_owned().to_lower()).collect()
    if ids.is_empty() || ids.any(x => x.is_empty()) {
      raise InvalidReference("Invalid search path identifiers")
    }
    let normalized = raw
      .replace_all(old="\\", new="/")
      .replace_all(old="|language|", new=language)
    let expanded = if normalized.has_prefix("|gameinfo_path|") {
      gameinfo_directory + "/" + normalized[15:].to_owned()
    } else if normalized.has_prefix("|all_source_engine_paths|") {
      engine_directory + "/" + normalized[25:].to_owned()
    } else {
      engine_directory + "/" + normalized
    }
    if expanded.contains("|") {
      raise InvalidReference("Unsupported gameinfo search path token")
    }
    let wildcard = expanded.has_suffix("/*")
    let directory = normalize_reference(
      if wildcard {
        expanded[:expanded.length() - 2].to_owned()
      } else {
        expanded
      },
    )
    if directory.contains("*") || directory.contains("?") {
      raise InvalidReference(
        "Only a trailing gameinfo /* wildcard is supported",
      )
    }
    output.push({ ids, directory, wildcard, })
  }
  output
}
