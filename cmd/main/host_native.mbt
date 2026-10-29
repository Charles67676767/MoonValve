///|
#borrow(path)
extern "C" fn native_read(path : Bytes, limit : Int) -> Bytes = "moonvalve_read"

///|
#borrow(path)
extern "C" fn native_list(path : Bytes) -> Bytes = "moonvalve_list"

///|
extern "C" fn native_failed() -> Int = "moonvalve_failed"

///|
#borrow(bytes)
extern "C" fn native_write(bytes : Bytes, length : Int, stderr : Int) -> Int = "moonvalve_write"

///|
extern "C" fn native_exit(code : Int) -> Unit = "moonvalve_exit"

///|
let exit_status : Ref[Int] = { val: 0, }

///|
#borrow(path)
extern "C" fn native_stream_open(path : Bytes) -> Int = "moonvalve_stream_open"

///|
extern "C" fn native_stream_chunk(handle : Int) -> Bytes = "moonvalve_stream_chunk"

///|
fn host_stream_chunk(handle : Int) -> Bytes raise CliError {
  let result = native_stream_chunk(handle)
  host_stream_check()
  result
}

///|
extern "C" fn host_stream_close(handle : Int) -> Unit = "moonvalve_stream_close"

///|
fn host_stream_check() -> Unit raise CliError {
  if native_failed() != 0 {
    raise InvalidArgument("Stream read failed")
  }
}

///|
fn host_stream_open(path : String) -> Int raise CliError {
  if path.contains("\u0000") || @utf8.encode(path[:]).length() > 32767 {
    raise InvalidArgument("Invalid stream path")
  }
  let result = native_stream_open(os_path(path))
  host_stream_check()
  result
}

///|
fn os_path(path : String) -> Bytes {
  @utf8.encode(path[:]) + b"\x00"
}

///|
fn host_read(path : String) -> FixedArray[String] {
  if path.contains("\u0000") || @utf8.encode(path[:]).length() > 32767 {
    return ["", "NUL in file path"]
  }
  let bytes = native_read(os_path(path), 16777216)
  if native_failed() != 0 {
    return ["", "Unable to read input or input exceeds 16 MiB"]
  }
  [@utf8.decode(bytes[:], ignore_bom=true), ""] catch {
    _ => ["", "Input is not valid UTF-8"]
  }
}

///|
fn host_read_bytes(
  path : String,
  limit? : Int = 16777216,
) -> Bytes raise CliError {
  if path.contains("\u0000") || @utf8.encode(path[:]).length() > 32767 {
    raise InvalidArgument("Invalid file path")
  }
  let bytes = native_read(os_path(path), limit)
  if native_failed() != 0 {
    raise InvalidArgument("Unable to read input or byte limit exceeded")
  }
  bytes
}

///|
fn host_output_bytes(bytes : Bytes) -> Unit {
  if native_write(bytes, bytes.length(), 0) != 0 {
    exit_status.val = 2
  }
}

///|
#borrow(root, relative)
extern "C" fn native_confined(root : Bytes, relative : Bytes) -> Bytes = "moonvalve_confined"

///|
fn host_confined(root : String, relative : String) -> String raise CliError {
  validate_reference_path(root, relative)
  let bytes = native_confined(os_path(root), os_path(relative))
  if native_failed() != 0 {
    raise InvalidArgument("Cannot resolve file within chosen root")
  }
  @utf8.decode(bytes[:]) catch {
    _ => raise InvalidArgument("Invalid path encoding")
  }
}

///|
#borrow(path, before, after)
extern "C" fn native_save(
  path : Bytes,
  before : Bytes,
  before_length : Int,
  after : Bytes,
  after_length : Int,
) -> Int = "moonvalve_save"

///|
fn host_save(
  path : String,
  before : Bytes,
  after : Bytes,
) -> Unit raise CliError {
  if path == "-" ||
    path.contains("\u0000") ||
    @utf8.encode(path[:]).length() > 32767 {
    raise InvalidArgument("Saving requires a valid file path")
  }
  if native_save(os_path(path), before, before.length(), after, after.length()) !=
    0 {
    raise InvalidArgument(
      "Save failed: input changed, backup exists, or filesystem error",
    )
  }
}

///|
fn host_output(text : String) -> Unit {
  let bytes = @utf8.encode(text[:])
  if native_write(bytes, bytes.length(), 0) != 0 {
    exit_status.val = 2
  }
}

///|
fn host_output_check() -> Unit raise CliError {
  if exit_status.val != 0 {
    raise InvalidArgument("Output stream failed")
  }
}

///|
fn host_error(message : String, code : Int) -> Unit {
  let bytes = @utf8.encode((message + "\n")[:])
  native_write(bytes, bytes.length(), 1) |> ignore
  exit_status.val = code
}

///|
fn host_exit_code(code : Int) -> Unit {
  exit_status.val = code
}

///|
fn host_finish() -> Unit {
  native_exit(exit_status.val)
}

///|
fn cli_args() -> Array[String] {
  ["", ..@env.args()]
}

///|
fn absolute_path(path : String) -> String {
  let path = path.replace_all(old="\\", new="/")
  let absolute = if path.has_prefix("/") ||
    (path.length() >= 2 && path[1] == ':') {
    path
  } else {
    @env.current_dir().unwrap_or(".").replace_all(old="\\", new="/") +
    "/" +
    path
  }
  let parts : Array[String] = []
  for part in absolute.split("/") {
    if part == "." || part.is_empty() {
      continue
    }
    if part == ".." &&
      !parts.is_empty() &&
      !parts[parts.length() - 1].has_suffix(":") {
      parts.pop() |> ignore
    } else {
      parts.push(part.to_owned())
    }
  }
  (if absolute.has_prefix("//") {
    "//"
  } else if absolute.has_prefix("/") {
    "/"
  } else {
    ""
  }) +
  parts.join("/")
}

///|
fn host_manifest_paths(source : String, library : String) -> FixedArray[String] {
  if source.contains("\u0000") || library.contains("\u0000") {
    return ["NUL in path"]
  }
  let source = absolute_path(source)
  let parent = match source.rev_find("/") {
    Some(i) => source[:i + 1].to_owned()
    None => ""
  }
  let base = if library.has_prefix("/") ||
    library.has_prefix("\\") ||
    (library.length() >= 2 && library[1] == ':') {
    library
  } else {
    parent + library
  }
  let directory = absolute_path(base + "/steamapps")
  let bytes = native_list(os_path(directory))
  if native_failed() != 0 {
    return ["Unable to list library or manifest limit exceeded"]
  }
  let text = @utf8.decode(bytes[:]) catch {
    _ => return ["Library contains a filename with invalid UTF-8"]
  }
  let files : Array[String] = []
  for name in text.split("\u0000") {
    if name.has_prefix("appmanifest_") && name.has_suffix(".acf") {
      let id = name[12:name.length() - 4]
      if !id.is_empty() && id.to_owned().all(c => c >= '0' && c <= '9') {
        files.push(directory + "/" + name.to_owned())
      }
    }
  }
  files.sort()
  FixedArray::makei(files.length() + 1, i => {
    if i == 0 {
      ""
    } else {
      files[i - 1]
    }
  })
}

///|
#borrow(path)
extern "C" fn native_export_begin(path : Bytes) -> Int = "moonvalve_export_begin"

///|
#borrow(path, bytes)
extern "C" fn native_export_file(
  path : Bytes,
  bytes : Bytes,
  length : Int,
) -> Int = "moonvalve_export_file"

///|
extern "C" fn native_export_finish(success : Int) -> Unit = "moonvalve_export_finish"

///|
fn host_export_directory(
  target : String,
  files : Map[String, String],
) -> Unit raise {
  host_export_binary_directory(
    target,
    files.map((_, text) => @utf8.encode(text[:])),
  )
}

///|
fn host_export_binary_directory(
  target : String,
  files : Map[String, Bytes],
) -> Unit raise {
  @valve.export_files_zip(files) |> ignore
  if target.is_empty() ||
    target == "-" ||
    target.contains("\u0000") ||
    @utf8.encode(target[:]).length() > 24000 {
    raise InvalidArgument("Invalid output directory")
  }
  if native_export_begin(os_path(target)) != 0 {
    raise InvalidArgument(
      "Output directory already exists or cannot be created; parent must exist",
    )
  }
  errdefer native_export_finish(0)
  {
    let names = files.keys().collect()
    names.sort_by((a, b) => a.lexical_compare(b))
    for name in names {
      let bytes = files[name]
      if native_export_file(os_path(name), bytes, bytes.length()) != 0 {
        raise InvalidArgument(
          "Directory export failed; owned output files were rolled back",
        )
      }
    }
  }
  native_export_finish(1)
}

///|
#borrow(path)
extern "C" fn native_read_range(
  path : Bytes,
  offset : Int,
  length : Int,
) -> Bytes = "moonvalve_read_range"

///|
fn host_read_range(path : String, offset : Int, length : Int) -> Bytes raise {
  if path == "-" ||
    path.contains("\u0000") ||
    @utf8.encode(path[:]).length() > 32767 ||
    offset < 0 ||
    length < 0 ||
    length > 67108864 {
    raise InvalidArgument("Invalid bounded file range")
  }
  let bytes = native_read_range(os_path(path), offset, length)
  if native_failed() != 0 {
    raise InvalidArgument("Unable to read complete archive byte range")
  }
  bytes
}

///|
#borrow(path, bytes)
extern "C" fn native_write_new(
  path : Bytes,
  bytes : Bytes,
  length : Int,
) -> Int = "moonvalve_write_new"

///|
fn host_write_new(target : String, bytes : Bytes) -> Unit raise {
  if target.is_empty() ||
    target == "-" ||
    target.contains("\u0000") ||
    @utf8.encode(target[:]).length() > 24000 {
    raise InvalidArgument("Invalid output filename")
  }
  if native_write_new(os_path(target), bytes, bytes.length()) != 0 {
    raise InvalidArgument("Output already exists or cannot be written")
  }
}
