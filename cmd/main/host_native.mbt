///|
#borrow(path)
extern "C" fn native_read(path : Bytes) -> Bytes = "moonvalve_read"

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
fn os_path(path : String) -> Bytes {
  @utf8.encode(path[:]) + b"\x00"
}

///|
fn host_read(path : String) -> FixedArray[String] {
  if path.contains("\u0000") || @utf8.encode(path[:]).length() > 32767 {
    return ["", "NUL in file path"]
  }
  let bytes = native_read(os_path(path))
  if native_failed() != 0 {
    return ["", "Unable to read input or input exceeds 16 MiB"]
  }
  [@utf8.decode(bytes[:], ignore_bom=true), ""] catch {
    _ => ["", "Input is not valid UTF-8"]
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
