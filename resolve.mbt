///|
pub suberror ResolveError {
  InvalidReference(String)
} derive(Debug)

///|
pub extend ResolveError with @debug.Debug::{to_repr}

///|
priv struct ResolveState {
  options : ParseOptions
  max_files : Int
  mut files : Int
  mut chars : Int
  mut entries : Int
}

///|
/// Load and resolve root-level includes and bases through an explicit loader.
/// Virtual paths use / separators. Budgets count every loaded file, including
/// repeated references, and entries parsed from filtered conditional branches.
pub fn load_resolved(
  source : String,
  loader : (String) -> String raise,
  options? : ParseOptions = ParseOptions::default(),
  max_files? : Int = 64,
) -> Document raise {
  if max_files < 1 || max_files > 256 {
    raise InvalidReference("max_files must be between 1 and 256")
  }
  let state = ResolveState::{
    options,
    max_files,
    files: 0,
    chars: 0,
    entries: 0,
  }
  resolve_file(normalize_reference(source), loader, [], state)
}

///|
fn normalize_reference(path : String) -> String raise ResolveError {
  let text = path.replace_all(old="\\", new="/")
  let rooted = text.has_prefix("/")
  let parts : Array[String] = []
  for part in text.split("/") {
    if part == "" || part == "." {
      continue
    }
    if part == ".." {
      if parts.is_empty() || (parts.length() == 1 && parts[0].has_suffix(":")) {
        raise InvalidReference("Reference escapes its virtual root")
      }
      parts.pop() |> ignore
    } else {
      parts.push(part.to_owned())
    }
  }
  if parts.is_empty() {
    raise InvalidReference("Empty file reference")
  }
  (if rooted { "/" } else { "" }) + parts.join("/")
}

///|
fn child_reference(
  parent : String,
  child : String,
) -> String raise ResolveError {
  if child.is_empty() ||
    child.has_prefix("/") ||
    child.has_prefix("\\") ||
    child.contains(":") {
    raise InvalidReference("Include/base paths must be relative")
  }
  let directory = match parent.rev_find("/") {
    Some(index) => parent[:index + 1].to_owned()
    None => ""
  }
  normalize_reference(directory + child)
}

///|
fn resolve_file(
  source : String,
  loader : (String) -> String raise,
  stack : Array[String],
  state : ResolveState,
) -> Document raise {
  if stack.contains(source) {
    raise InvalidReference("Cyclic reference: " + source)
  }
  if state.files >= state.max_files {
    raise InvalidReference("File count exceeds max_files")
  }
  state.files += 1
  let text = loader(source) catch {
    error =>
      raise InvalidReference("Cannot load " + source + ": " + error.to_string())
  }
  let chars = text.char_length()
  if chars > state.options.max_input_chars - state.chars {
    raise InvalidReference("Referenced input exceeds global character budget")
  }
  state.chars += chars
  let (doc, count) = parse_internal(text, state.options, true)
  if count > state.options.max_entries - state.entries {
    raise InvalidReference("Referenced input exceeds global entry budget")
  }
  state.entries += count
  let next = stack.map(s => s)
  next.push(source)
  let result : Array[Entry] = []
  let includes : Array[String] = []
  let bases : Array[String] = []
  for entry in doc.entries {
    let is_include = entry.key.equal_ignore_ascii_case("#include")
    let base = entry.key.equal_ignore_ascii_case("#base")
    if is_include || base {
      guard entry.value is Text(path) else {
        raise InvalidReference("Directive value must be a file path")
      }
      if is_include {
        includes.push(path)
      } else {
        bases.push(path)
      }
    } else {
      result.push(entry)
    }
  }
  for reference in includes {
    let included = resolve_file(
      child_reference(source, reference),
      loader,
      next,
      state,
    )
    for entry in included.entries {
      result.push(entry)
    }
  }
  let mut merged = result
  for reference in bases {
    let base = resolve_file(
      child_reference(source, reference),
      loader,
      next,
      state,
    )
    merged = merge_base(merged, base.entries)
  }
  { entries: merged, }
}

///|
/// Pair duplicate keys by occurrence when merging; existing scalar values win.
fn merge_base(current : Array[Entry], base : Array[Entry]) -> Array[Entry] {
  let result = current.map(e => e)
  let positions : Map[String, Array[Int]] = Map([])
  let occurrences : Map[String, Int] = Map([])
  for i in 0..<result.length() {
    let key = reference_key(result[i].key)
    match positions.get(key) {
      Some(indices) => indices.push(i)
      None => positions[key] = [i]
    }
  }
  for entry in base {
    let key = reference_key(entry.key)
    let occurrence = occurrences.get(key).unwrap_or(0)
    occurrences[key] = occurrence + 1
    let found = match positions.get(key) {
      Some(indices) => indices.get(occurrence)
      None => None
    }
    match found {
      None => {
        match positions.get(key) {
          Some(indices) => indices.push(result.length())
          None => positions[key] = [result.length()]
        }
        result.push(entry)
      }
      Some(i) =>
        match (result[i].value, entry.value) {
          (Object(children), Object(defaults)) =>
            result[i] = {
              key: result[i].key,
              value: Object(merge_base(children, defaults)),
            }
          _ => ()
        }
    }
  }
  result
}

///|
fn reference_key(key : String) -> String {
  let builder = StringBuilder()
  for c in key {
    builder.write_char(
      if c >= 'A' && c <= 'Z' {
        (c.to_int() + 32).to_char().unwrap()
      } else {
        c
      },
    )
  }
  builder.to_string()
}
