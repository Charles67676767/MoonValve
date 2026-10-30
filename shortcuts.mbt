///|
pub(all) struct SteamShortcut {
  index : String
  app_id : UInt32
  name : String
  exe : String
  start_dir : String
  launch_options : String
  tags : Array[String]
} derive(Eq, Debug)

///|
pub extend SteamShortcut with Eq::{equal, not_equal}

///|
pub extend SteamShortcut with @debug.Debug::{to_repr}

///|
struct ShortcutFile {
  entries : Array[BinaryEntry]
}

///|
pub fn new_shortcut_file() -> ShortcutFile {
  { entries: [{ key: "shortcuts", value: ObjectValue([]), }], }
}

///|
pub fn read_shortcut_file(
  entries : Array[BinaryEntry],
) -> ShortcutFile raise SteamError {
  let result = ShortcutFile::{ entries, }
  result.shortcuts() |> ignore
  result
}

///|
fn binary_field(entries : Array[BinaryEntry], key : String) -> BinaryValue? {
  for entry in entries {
    if entry.key.equal_ignore_ascii_case(key) {
      return Some(entry.value)
    }
  }
  None
}

///|
fn shortcut_text(
  fields : Array[BinaryEntry],
  key : String,
  required : Bool,
) -> String raise SteamError {
  match binary_field(fields, key) {
    Some(StringValue(text)) => text
    None if !required => ""
    _ => raise InvalidManifest("Invalid shortcut text field: " + key)
  }
}

///|
fn ShortcutFile::root_index(self : ShortcutFile) -> Int32 raise SteamError {
  let mut result = -1
  for i in 0..<self.entries.length() {
    if self.entries[i].key.equal_ignore_ascii_case("shortcuts") {
      if result >= 0 {
        raise InvalidManifest("Duplicate shortcuts root")
      }
      result = i
    }
  }
  if result < 0 {
    raise InvalidManifest("Missing shortcuts root")
  }
  result
}

///|
fn ShortcutFile::children(
  self : ShortcutFile,
) -> Array[BinaryEntry] raise SteamError {
  guard self.entries[self.root_index()].value is ObjectValue(children) else {
    raise InvalidManifest("shortcuts root must be an object")
  }
  children
}

///|
pub fn ShortcutFile::shortcuts(
  self : ShortcutFile,
) -> Array[SteamShortcut] raise SteamError {
  let result : Array[SteamShortcut] = []
  let indices : Map[String, Bool] = Map([])
  for entry in self.children() {
    if indices.contains(entry.key) {
      raise InvalidManifest("Duplicate shortcut index")
    }
    indices[entry.key] = true
    guard entry.value is ObjectValue(fields) else {
      raise InvalidManifest("Shortcut entry must be an object")
    }
    let name = shortcut_text(fields, "AppName", true)
    let exe = shortcut_text(fields, "exe", true)
    let app_id = match binary_field(fields, "appid") {
      Some(Int32Value(n)) => n.reinterpret_as_uint()
      None => shortcut_app_id(name, exe)
      _ => raise InvalidManifest("Shortcut appid must be Int32")
    }
    let tags = match binary_field(fields, "tags") {
      None => []
      Some(ObjectValue(tags)) =>
        tags.map(tag => {
          match tag.value {
            StringValue(s) => s
            _ => raise InvalidManifest("Shortcut tag must be text")
          }
        })
      _ => raise InvalidManifest("Shortcut tags must be an object")
    }
    result.push({
      index: entry.key,
      app_id,
      name,
      exe,
      start_dir: shortcut_text(fields, "StartDir", false),
      launch_options: shortcut_text(fields, "LaunchOptions", false),
      tags,
    })
  }
  result
}

///|
/// Stable Steam shortcut identifier: CRC-32/ISO-HDLC(exe + name), high bit set.
pub fn shortcut_app_id(name : String, exe : String) -> UInt32 {
  let mut crc = 0xffffffffU
  for byte in @utf8.encode((exe + name)[:]) {
    crc = crc ^ byte.to_uint()
    for _ in 0..<8 {
      crc = if (crc & 1U) != 0U { (crc >> 1) ^ 0xedb88320U } else { crc >> 1 }
    }
  }
  (crc ^ 0xffffffffU) | 0x80000000U
}

///|
pub fn SteamShortcut::url(self : SteamShortcut) -> String {
  "steam://rungameid/" +
  ((self.app_id.to_uint64() << 32) | 0x02000000UL).to_string()
}

///|
pub fn ShortcutFile::to_binary(self : ShortcutFile) -> Array[BinaryEntry] {
  self.entries
}

///|
fn ShortcutFile::with_children(
  self : ShortcutFile,
  children : Array[BinaryEntry],
) -> ShortcutFile raise SteamError {
  let index = self.root_index()
  let entries = self.entries.map(e => e)
  entries[index] = { key: entries[index].key, value: ObjectValue(children), }
  read_shortcut_file(entries)
}

///|
/// Replace modeled fields while retaining unknown fields and all other entries.
/// The supplied app_id is kept exactly; callers can deliberately preserve identity.
pub fn ShortcutFile::set(
  self : ShortcutFile,
  shortcut : SteamShortcut,
) -> ShortcutFile raise SteamError {
  let children = self.children().map(e => e)
  let mut position = -1
  for i in 0..<children.length() {
    if children[i].key == shortcut.index {
      position = i
      break
    }
  }
  if position < 0 {
    raise InvalidManifest("Shortcut index does not exist")
  }
  guard children[position].value is ObjectValue(original) else {
    raise InvalidManifest("Shortcut is not an object")
  }
  let tags = shortcut.tags.map(s => BinaryEntry::{
    key: "",
    value: StringValue(s),
  })
  for i in 0..<tags.length() {
    tags[i] = { ..tags[i], key: i.to_string(), }
  }
  let replacements : Array[BinaryEntry] = [
    { key: "appid", value: Int32Value(shortcut.app_id.reinterpret_as_int()), },
    { key: "AppName", value: StringValue(shortcut.name), },
    { key: "exe", value: StringValue(shortcut.exe), },
    { key: "StartDir", value: StringValue(shortcut.start_dir), },
    { key: "LaunchOptions", value: StringValue(shortcut.launch_options), },
    { key: "tags", value: ObjectValue(tags), },
  ]
  let fields = original.map(e => e)
  for replacement in replacements {
    let mut replaced = false
    for i in 0..<fields.length() {
      if fields[i].key.equal_ignore_ascii_case(replacement.key) {
        fields[i] = { key: fields[i].key, value: replacement.value, }
        replaced = true
      }
    }
    if !replaced {
      fields.push(replacement)
    }
  }
  children[position] = { key: shortcut.index, value: ObjectValue(fields), }
  self.with_children(children)
}

///|
pub fn ShortcutFile::add(
  self : ShortcutFile,
  name : String,
  exe : String,
  start_dir~ : String = "",
  launch_options~ : String = "",
  tags~ : Array[String] = [],
) -> ShortcutFile raise SteamError {
  if name.is_empty() || exe.is_empty() {
    raise InvalidManifest("Shortcut name and executable must not be empty")
  }
  let children = self.children().map(e => e)
  let indices : Map[String, Bool] = Map([])
  for entry in children {
    indices[entry.key] = true
  }
  let mut index = 0
  while indices.contains(index.to_string()) {
    index += 1
  }
  let key = index.to_string()
  children.push({ key, value: ObjectValue([]), })
  let raw = ShortcutFile::{ entries: self.entries.map(e => e), }
  let entries = raw.entries.map(e => e)
  let root = raw.root_index()
  entries[root] = { key: entries[root].key, value: ObjectValue(children), }
  ShortcutFile::{ entries, }.set({
    index: key,
    app_id: shortcut_app_id(name, exe),
    name,
    exe,
    start_dir,
    launch_options,
    tags,
  })
}

///|
pub fn ShortcutFile::remove(
  self : ShortcutFile,
  index : String,
) -> ShortcutFile raise SteamError {
  let children = self.children()
  if !children.any(e => e.key == index) {
    raise InvalidManifest("Shortcut index does not exist")
  }
  self.with_children(children.filter(e => e.key != index))
}
