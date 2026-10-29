///|
pub(all) struct VPKEntry {
  path : String
  crc32 : UInt
  preload : Bytes
  archive : Int
  offset : Int
  length : Int
} derive(Eq, Debug)

///|
pub extend VPKEntry with Eq::{equal, not_equal}

///|
pub extend VPKEntry with @debug.Debug::{to_repr}

///|
struct VPKArchive {
  version : Int
  entries : Array[VPKEntry]
  lookup : Map[String, Int]
  directory : Bytes
  data_offset : Int
  data_size : Int
}

///|
pub fn VPKArchive::version(self : VPKArchive) -> Int {
  self.version
}

///|
pub fn VPKArchive::embedded_size(self : VPKArchive) -> Int? {
  if self.data_size < 0 {
    None
  } else {
    Some(self.data_size)
  }
}

///|
pub fn VPKArchive::entries(self : VPKArchive) -> Array[VPKEntry] {
  self.entries.copy()
}

///|
pub fn VPKArchive::find(self : VPKArchive, path : String) -> VPKEntry? {
  self.lookup
  .get(path.replace_all(old="\\", new="/").to_lower())
  .map(i => self.entries[i])
}

///|
/// Only directory metadata is required. Embedded bytes can be supplied later by
/// the range loader; numbered archives are never eagerly read by this API.
pub fn read_vpk(
  bytes : Bytes,
  options? : BinaryOptions = BinaryOptions::default(),
) -> VPKArchive raise {
  check_binary_options(options)
  if bytes.length() > options.max_bytes {
    raise InvalidBinary(0, "VPK directory exceeds byte budget")
  }
  let input = valve_bytes(bytes)
  if input.uint(4) != 0x55aa1234UL {
    raise InvalidBinary(0, "Expected Valve VPK signature")
  }
  let version = input.uint(4).to_int()
  if version != 1 && version != 2 {
    raise InvalidBinary(4, "Unsupported VPK version")
  }
  let size = input.count(options.max_bytes)
  let mut data_size = -1
  if version == 2 {
    data_size = input.count(2147483647)
    let archive_md5 = input.count(2147483647)
    let other_md5 = input.count(2147483647)
    let signature = input.count(2147483647)
    if archive_md5 % 28 != 0 ||
      (other_md5 != 0 && other_md5 != 48) ||
      (signature != 0 && signature < 8) {
      raise InvalidBinary(input.pos, "Invalid VPK v2 footer section sizes")
    }
  }
  let start = input.pos
  let tree = valve_bytes(input.take(size))
  let entries : Array[VPKEntry] = []
  let lookup : Map[String, Int] = Map([])
  while true {
    let extension = tree.cstring(options.max_string_bytes)
    if extension.is_empty() {
      break
    }
    if extension != " " &&
      (
        extension.contains("/") ||
        extension.contains("\\") ||
        extension.contains(".")
      ) {
      raise InvalidBinary(tree.pos, "Invalid VPK extension")
    }
    while true {
      let directory = tree.cstring(options.max_string_bytes)
      if directory.is_empty() {
        break
      }
      while true {
        let name = tree.cstring(options.max_string_bytes)
        if name.is_empty() {
          break
        }
        if name.contains("/") || name.contains("\\") {
          raise InvalidBinary(tree.pos, "Invalid VPK leaf name")
        }
        let path = (if directory == " " { "" } else { directory + "/" }) +
          name +
          (if extension == " " { "" } else { "." + extension })
        if !resource_relative(path) || lookup.contains(path.to_lower()) {
          raise InvalidBinary(tree.pos, "Unsafe or duplicate VPK path")
        }
        let crc32 = tree.uint(4).to_uint()
        let preload_size = tree.uint(2).to_int()
        let archive = tree.uint(2).to_int()
        let offset = tree.count(2147483647)
        let length = tree.count(options.max_bytes)
        if length > options.max_bytes - preload_size ||
          offset > 2147483647 - length {
          raise InvalidBinary(tree.pos, "VPK entry range exceeds budget")
        }
        if tree.uint(2) != 65535UL {
          raise InvalidBinary(tree.pos, "Invalid VPK entry terminator")
        }
        let preload = tree.take(preload_size)
        if version == 2 &&
          archive == 32767 &&
          (offset > data_size || length > data_size - offset) {
          raise InvalidBinary(tree.pos, "VPK entry exceeds embedded section")
        }
        if entries.length() >= options.max_entries {
          raise InvalidBinary(tree.pos, "VPK entry count exceeds budget")
        }
        lookup[path.to_lower()] = entries.length()
        entries.push({ path, crc32, preload, archive, offset, length, })
      }
    }
  }
  if tree.remaining() != 0 {
    raise InvalidBinary(start + tree.pos, "Trailing VPK directory bytes")
  }
  {
    version,
    entries,
    lookup,
    directory: bytes,
    data_offset: start + size,
    data_size,
  }
}

///|
/// Loader arguments are archive index, absolute byte offset and byte count.
/// Index 0x7fff refers to the directory file. CRC covers preload plus body.
pub fn VPKArchive::read(
  self : VPKArchive,
  path : String,
  loader : (Int, Int, Int) -> Bytes raise,
  verify_crc? : Bool = true,
) -> Bytes raise {
  guard self.find(path) is Some(entry) else {
    raise InvalidReference("VPK path was not found: " + path)
  }
  let output = @buffer.Buffer()
  output.write_bytes(entry.preload[:])
  if entry.length > 0 {
    let base = if entry.archive == 32767 { self.data_offset } else { 0 }
    if entry.offset > 2147483647 - base - entry.length {
      raise InvalidBinary(0, "VPK absolute range overflow")
    }
    let offset = base + entry.offset
    let body = if entry.archive == 32767 &&
      offset <= self.directory.length() &&
      entry.length <= self.directory.length() - offset {
      self.directory[offset:offset + entry.length].to_owned()
    } else {
      loader(entry.archive, offset, entry.length)
    }
    if body.length() != entry.length {
      raise InvalidBinary(
        offset, "VPK range loader returned an incorrect length",
      )
    }
    output.write_bytes(body[:])
  }
  let bytes = output.to_bytes()
  if verify_crc && zip_crc32(bytes) != entry.crc32 {
    raise InvalidBinary(0, "VPK file CRC32 mismatch: " + entry.path)
  }
  bytes
}

///|
fn vpk_cstring(output : @buffer.Buffer, value : String) -> Unit {
  output.write_bytes(@utf8.encode(value[:])[:])
  output.write_byte(b'\x00')
}

///|
/// Deterministic embedded VPK v1. File names are case-insensitive, contents are
/// uncompressed and CRC32 is computed over the complete original byte stream.
pub fn create_vpk(
  files : Map[String, Bytes],
  preload_bytes? : Int = 0,
  options? : BinaryOptions = BinaryOptions::default(),
) -> Bytes raise {
  check_binary_options(options)
  if preload_bytes < 0 ||
    preload_bytes > 65535 ||
    files.length() > options.max_entries {
    raise InvalidBinary(0, "Invalid VPK creation limits")
  }
  let groups : Map[String, Map[String, Array[(String, String)]]] = Map([])
  let names : Map[String, Bool] = Map([])
  let mut total = 0
  for (path, bytes) in files {
    if !resource_relative(path) || names.contains(path.to_lower()) {
      raise InvalidReference("Unsafe or duplicate VPK output path")
    }
    names[path.to_lower()] = true
    if bytes.length() > options.max_bytes - total {
      raise InvalidBinary(0, "VPK aggregate byte budget exceeded")
    }
    total += bytes.length()
    let parts = path.split("/").map(x => x.to_owned()).collect()
    let leaf = parts[parts.length() - 1]
    let dot_parts = leaf.split(".").map(x => x.to_owned()).collect()
    let extension = if dot_parts.length() > 1 &&
      !dot_parts[dot_parts.length() - 1].is_empty() {
      dot_parts[dot_parts.length() - 1]
    } else {
      " "
    }
    let name = if extension == " " {
      leaf
    } else {
      leaf[:leaf.length() - extension.length() - 1].to_owned()
    }
    if name.is_empty() || (extension == " " && leaf == " ") {
      raise InvalidReference("VPK file name cannot be represented")
    }
    let directory = if parts.length() == 1 {
      " "
    } else {
      parts[:parts.length() - 1].to_owned().join("/")
    }
    let paths = groups.get(extension).unwrap_or(Map([]))
    groups[extension] = paths
    let leaves = paths.get(directory).unwrap_or([])
    paths[directory] = leaves
    leaves.push((name, path))
  }
  let tree = @buffer.Buffer()
  let data = @buffer.Buffer()
  let extensions = groups.keys().collect()
  extensions.sort_by((a, b) => a.lexical_compare(b))
  for extension in extensions {
    vpk_cstring(tree, extension)
    let directories = groups[extension].keys().collect()
    directories.sort_by((a, b) => a.lexical_compare(b))
    for directory in directories {
      vpk_cstring(tree, directory)
      let leaves = groups[extension][directory]
      leaves.sort_by((a, b) => a.0.lexical_compare(b.0))
      for (name, path) in leaves {
        let bytes = files[path]
        let preload = bytes.length().min(preload_bytes)
        vpk_cstring(tree, name)
        valve_uint(tree, zip_crc32(bytes).to_uint64(), 4)
        valve_uint(tree, preload.to_uint64(), 2)
        valve_uint(tree, 32767UL, 2)
        valve_uint(tree, data.length().to_uint64(), 4)
        valve_uint(tree, (bytes.length() - preload).to_uint64(), 4)
        valve_uint(tree, 65535UL, 2)
        tree.write_bytes(bytes[:preload])
        data.write_bytes(bytes[preload:])
      }
      tree.write_byte(b'\x00')
    }
    tree.write_byte(b'\x00')
  }
  tree.write_byte(b'\x00')
  if tree.length() + data.length() > options.max_bytes - 12 {
    raise InvalidBinary(0, "VPK output exceeds byte budget")
  }
  let output = @buffer.Buffer()
  valve_uint(output, 0x55aa1234UL, 4)
  valve_uint(output, 1UL, 4)
  valve_uint(output, tree.length().to_uint64(), 4)
  output.write_bytes(tree.to_bytes()[:])
  output.write_bytes(data.to_bytes()[:])
  output.to_bytes()
}
