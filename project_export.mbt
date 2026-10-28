///|
fn portable_project_path(name : String) -> String raise {
  workspace_path(name) |> ignore
  if @utf8.encode(name[:]).length() > 4096 {
    raise InvalidReference("Export path exceeds 4096 bytes")
  }
  if name.split("/").count() > 64 {
    raise InvalidReference("Export path exceeds 64 components")
  }
  for component in name.split("/") {
    let part = component.to_owned()
    if @utf8.encode(part[:]).length() > 255 {
      raise InvalidReference("Export filename exceeds 255 UTF-8 bytes")
    }
    let base = part.split(".").next().unwrap_or("").to_owned().to_lower()
    if part.has_suffix(".") ||
      part.has_suffix(" ") ||
      part.any(c => {
        c.to_int() < 32 ||
        c.to_int() == 127 ||
        "<>:\"\\|?*".contains(c.to_string())
      }) ||
      [
        "con", "prn", "aux", "nul", "clock$", "com¹", "com²", "com³", "lpt¹",
        "lpt²", "lpt³", "conin$", "conout$", "com1", "com2", "com3", "com4", "com5",
        "com6", "com7", "com8", "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6",
        "lpt7", "lpt8", "lpt9",
      ].contains(base) {
      raise InvalidReference("Export requires portable relative filenames")
    }
  }
  name
}

///|
/// Validate all contents and portable paths before hosts create any output.
/// Only the files explicitly contained in the snapshot are exported.
pub fn project_export_files(
  snapshot : Json,
  options? : ParseOptions = ParseOptions::default(),
) -> Map[String, String] raise {
  guard snapshot is Object(fields) &&
    fields.get("format") == Some(Json::string("moonvalve-project-v1")) &&
    fields.get("source") is Some(String(source)) &&
    fields.get("files") is Some(Object(rows)) &&
    rows.length() > 0 &&
    rows.length() <= 64 else {
    raise InvalidReference("Expected a project snapshot containing 1..64 files")
  }
  let output : Map[String, String] = Map([])
  let names : Map[String, Bool] = Map([])
  let mut total = 0
  for name, value in rows {
    portable_project_path(name) |> ignore
    let lower = name.to_lower()
    if names.contains(lower) {
      raise InvalidReference("Case-insensitive export filename collision")
    }
    names[lower] = true
    guard value is String(text) else {
      raise InvalidReference("Expected text file contents")
    }
    total += @utf8.encode(text[:]).length()
    if total > 67108864 {
      raise InvalidReference("Project export exceeds 64 MiB")
    }
    if name.to_lower().has_suffix(".kv3") ||
      text.trim_start().to_owned().has_prefix("<!-- kv3") {
      parse_kv3(text, options~) |> ignore
    } else {
      parse_preserving(text, options~) |> ignore
    }
    output[name] = text
  }
  if !output.contains(source) {
    raise InvalidReference("Project entry file is missing")
  }
  for name, _ in names {
    let parts = name.split("/").map(s => s.to_owned()).collect()
    for i in 1..<parts.length() {
      if names.contains(parts[:i].to_owned().join("/")) {
        raise InvalidReference("Export file conflicts with a directory")
      }
    }
  }
  output
}

///|
fn zip_crc32(bytes : Bytes) -> UInt {
  let mut crc = 0xffffffffU
  for byte in bytes {
    crc = crc ^ byte.to_uint()
    for _ in 0..<8 {
      crc = if (crc & 1U) != 0U { (crc >> 1) ^ 0xedb88320U } else { crc >> 1 }
    }
  }
  crc ^ 0xffffffffU
}

///|
fn zip_u16(buffer : @buffer.Buffer, n : Int) -> Unit {
  buffer.write_byte((n & 255).to_byte())
  buffer.write_byte(((n >> 8) & 255).to_byte())
}

///|
fn zip_u32(buffer : @buffer.Buffer, n : Int) -> Unit {
  buffer.write_uint_le(n.reinterpret_as_uint())
}

///|
/// Deterministic ZIP32, stored entries, UTF-8 names, CRC32 and central directory.
/// No compressor, archive reader or filesystem access is required.
pub fn export_project_zip(
  snapshot : Json,
  options? : ParseOptions = ParseOptions::default(),
) -> Bytes raise {
  let files = project_export_files(snapshot, options~)
  let names = files.keys().collect()
  names.sort_by((a, b) => a.lexical_compare(b))
  let output = @buffer.Buffer()
  let directory = @buffer.Buffer()
  for name in names {
    let filename = @utf8.encode(name[:])
    let data = @utf8.encode(files[name][:])
    let crc = zip_crc32(data)
    let offset = output.length()
    zip_u32(output, 0x04034b50)
    for n in [20, 0x800, 0, 0, 33] {
      zip_u16(output, n)
    }
    output.write_uint_le(crc)
    zip_u32(output, data.length())
    zip_u32(output, data.length())
    zip_u16(output, filename.length())
    zip_u16(output, 0)
    output.write_bytes(filename[:])
    output.write_bytes(data[:])
    zip_u32(directory, 0x02014b50)
    for n in [20, 20, 0x800, 0, 0, 33] {
      zip_u16(directory, n)
    }
    directory.write_uint_le(crc)
    zip_u32(directory, data.length())
    zip_u32(directory, data.length())
    for n in [filename.length(), 0, 0, 0, 0] {
      zip_u16(directory, n)
    }
    zip_u32(directory, 0)
    zip_u32(directory, offset)
    directory.write_bytes(filename[:])
  }
  let offset = output.length()
  output.write_bytes(directory.to_bytes()[:])
  zip_u32(output, 0x06054b50)
  for n in [0, 0, names.length(), names.length()] {
    zip_u16(output, n)
  }
  zip_u32(output, directory.length())
  zip_u32(output, offset)
  zip_u16(output, 0)
  output.to_bytes()
}
