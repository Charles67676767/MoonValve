///|
/// Immutable in-memory KV1 workspace. Operations return a new snapshot; hosts
/// decide how to present or save it. No multi-file filesystem atomicity is claimed.
struct Workspace {
  documents : Map[String, SourceDocument]
  options : ParseOptions
}

///|
fn workspace_path(name : String) -> String raise {
  if name.is_empty() ||
    name.has_prefix("/") ||
    name.contains("\\") ||
    name.contains(":") ||
    name.contains("\u0000") ||
    normalize_reference(name) != name {
    raise InvalidReference("Workspace paths must be normalized relative names")
  }
  name
}

///|
pub fn new_workspace(
  files : Map[String, String],
  options? : ParseOptions = ParseOptions::default(),
) -> Workspace raise {
  if files.is_empty() || files.length() > 64 {
    raise InvalidReference("Workspace requires 1..64 files")
  }
  let documents : Map[String, SourceDocument] = Map([])
  let mut total = 0
  for name, text in files {
    workspace_path(name) |> ignore
    total += text.char_length()
    if total > 16777216 {
      raise InvalidReference("Workspace exceeds 16 million characters")
    }
    documents[name] = parse_preserving(text, options~)
  }
  { documents, options, }
}

///|
pub fn Workspace::files(self : Workspace) -> Map[String, String] {
  let files : Map[String, String] = Map([])
  for name, document in self.documents {
    files[name] = document.text()
  }
  files
}

///|
fn relative_reference(source : String, target : String) -> String {
  let parent = source.split("/").map(s => s.to_owned()).collect()
  parent.pop() |> ignore
  let parts = target.split("/").map(s => s.to_owned()).collect()
  let mut common = 0
  while common < parent.length() &&
        common < parts.length() &&
        parent[common] == parts[common] {
    common += 1
  }
  let result : Array[String] = []
  for _ in common..<parent.length() {
    result.push("..")
  }
  for i in common..<parts.length() {
    result.push(parts[i])
  }
  result.join("/")
}

///|
fn rewritten_references(
  document : SourceDocument,
  old_name : String,
  new_name : String,
  moved_from : String?,
  moved_to : String?,
) -> SourceDocument raise {
  let changes : Array[Change] = []
  let occurrences : Map[String, Int] = Map([])
  for entry in document.doc.entries {
    let occurrence = occurrences.get(entry.key).unwrap_or(0)
    occurrences[entry.key] = occurrence + 1
    if !entry.key.equal_ignore_ascii_case("#include") &&
      !entry.key.equal_ignore_ascii_case("#base") {
      continue
    }
    guard entry.value is Text(reference) else {
      raise InvalidReference("Reference must have a text path")
    }
    let original_target = child_reference(old_name, reference)
    let target = if moved_from == Some(original_target) {
      moved_to.unwrap()
    } else {
      original_target
    }
    if target != original_target || old_name != new_name {
      let path = relative_reference(new_name, target)
      if path != reference {
        changes.push({
          path: [{ key: entry.key, occurrence, }],
          operation: Replace(Text(path)),
        })
      }
    }
  }
  if changes.is_empty() {
    document
  } else {
    document.apply_snapshot(changes)
  }
}

///|
/// Rename incoming references, including inactive branches, and rebase outgoing
/// references when the moved file changes directory.
pub fn Workspace::rename_file(
  self : Workspace,
  from : String,
  to : String,
) -> Workspace raise {
  workspace_path(from) |> ignore
  workspace_path(to) |> ignore
  if !self.documents.contains(from) {
    raise InvalidReference("Source file does not exist")
  }
  if from == to {
    return self
  }
  if self.documents.contains(to) {
    raise InvalidReference("Destination already exists")
  }
  let files : Map[String, String] = Map([])
  for name, document in self.documents {
    let renamed = if name == from { to } else { name }
    files[renamed] = rewritten_references(
      document,
      name,
      renamed,
      Some(from),
      Some(to),
    ).text()
  }
  new_workspace(files, options=self.options)
}

///|
pub fn Workspace::copy_file(
  self : Workspace,
  from : String,
  to : String,
) -> Workspace raise {
  workspace_path(to) |> ignore
  guard self.documents.get(from) is Some(document) else {
    raise InvalidReference("Source file does not exist")
  }
  if self.documents.contains(to) {
    raise InvalidReference("Destination already exists")
  }
  let files = self.files()
  files[to] = rewritten_references(document, from, to, None, None).text()
  new_workspace(files, options=self.options)
}

///|
pub fn Workspace::add_file(
  self : Workspace,
  name : String,
  text : String,
) -> Workspace raise {
  workspace_path(name) |> ignore
  if self.documents.contains(name) {
    raise InvalidReference("File already exists")
  }
  let files = self.files()
  files[name] = text
  new_workspace(files, options=self.options)
}

///|
pub fn Workspace::remove_file(
  self : Workspace,
  name : String,
) -> Workspace raise {
  if !self.documents.contains(name) {
    raise InvalidReference("File does not exist")
  }
  let files : Map[String, String] = Map([])
  for source, document in self.documents {
    if source == name {
      continue
    }
    for entry in document.doc.entries {
      if entry.key.equal_ignore_ascii_case("#include") ||
        entry.key.equal_ignore_ascii_case("#base") {
        guard entry.value is Text(path) else {
          raise InvalidReference("Invalid file directive")
        }
        if child_reference(source, path) == name {
          raise InvalidReference("File is still referenced by " + source)
        }
      }
    }
    files[source] = document.text()
  }
  new_workspace(files, options=self.options)
}

///|
pub fn Workspace::apply(self : Workspace, plan : Json) -> Workspace raise {
  guard plan is Array(changes) && changes.length() <= 1000 else {
    raise InvalidReference("Expected at most 1000 workspace operations")
  }
  let mut result = self
  for change in changes {
    guard change is Object(row) && row.get("op") is Some(String(op)) else {
      raise InvalidReference("Invalid workspace operation")
    }
    result = match op {
      "query" if row.length() == 4 &&
        row.get("expression") is Some(String(expression)) &&
        row.get("operation") is Some(operation) &&
        row.get("files") is Some(files) =>
        result.edit_query(
          expression,
          query_edit_from_json(operation),
          files=workspace_selection(files),
        )
      "rename" | "copy" if row.length() == 3 &&
        row.get("from") is Some(String(from)) &&
        row.get("to") is Some(String(to)) =>
        if op == "rename" {
          result.rename_file(from, to)
        } else {
          result.copy_file(from, to)
        }
      "add" if row.length() == 3 &&
        row.get("name") is Some(String(name)) &&
        row.get("text") is Some(String(text)) => result.add_file(name, text)
      "remove" if row.length() == 2 && row.get("name") is Some(String(name)) =>
        result.remove_file(name)
      _ => raise InvalidReference("Unknown workspace operation or fields")
    }
  }
  result
}

///|
pub fn workspace_from_json(
  json : Json,
  options? : ParseOptions = ParseOptions::default(),
) -> Workspace raise {
  guard json is Object(rows) else {
    raise InvalidReference("Expected a workspace file map")
  }
  let files : Map[String, String] = Map([])
  for name, value in rows {
    guard value is String(text) else {
      raise InvalidReference("Workspace file contents must be text")
    }
    files[name] = text
  }
  new_workspace(files, options~)
}

///|
pub fn Workspace::to_json(self : Workspace) -> Json {
  let rows : Map[String, Json] = Map([])
  for name, document in self.documents {
    rows[name] = Json::string(document.text())
  }
  Json::object(rows)
}

///|
pub fn edit_workspace_snapshot(
  snapshot : Json,
  plan : Json,
  options? : ParseOptions = ParseOptions::default(),
) -> Json raise {
  guard snapshot is Object(fields) &&
    fields.get("format") == Some(Json::string("moonvalve-project-v1")) &&
    fields.get("source") is Some(String(source)) &&
    fields.get("files") is Some(files) else {
    raise InvalidReference("Expected MoonValve project snapshot")
  }
  guard plan is Array(changes) && changes.length() <= 1000 else {
    raise InvalidReference("Expected bounded workspace plan")
  }
  let mut workspace = workspace_from_json(files, options~)
  let mut entry = source
  if !workspace.documents.contains(entry) {
    raise InvalidReference("Snapshot entry is missing")
  }
  for change in changes {
    workspace = workspace.apply(Json::array([change]))
    if change is Object(row) &&
      row.get("op") == Some(Json::string("rename")) &&
      row.get("from") == Some(Json::string(entry)) &&
      row.get("to") is Some(String(to)) {
      entry = to
    }
    if !workspace.documents.contains(entry) {
      let names = workspace.documents.keys().collect()
      names.sort()
      entry = names[0]
    }
  }
  Json::object({
    "format": Json::string("moonvalve-project-v1"),
    "source": Json::string(entry),
    "files": workspace.to_json(),
  })
}

///|
fn workspace_selection(json : Json) -> Array[String] raise {
  guard json is Array(values) && values.length() <= 64 else {
    raise InvalidQuery("Expected at most 64 selected files")
  }
  values.map(value => {
    guard value is String(name) else {
      raise InvalidQuery("Expected selected file names")
    }
    name
  })
}

///|
fn Workspace::selected_names(
  self : Workspace,
  files : Array[String],
) -> Array[String] raise {
  let selected : Map[String, Bool] = Map([])
  for name in files {
    if !self.documents.contains(name) || selected.contains(name) {
      raise InvalidQuery("Missing or duplicate selected file")
    }
    selected[name] = true
  }
  let names = if files.is_empty() {
    self.documents.keys().collect()
  } else {
    files.map(s => s)
  }
  names.sort_by((a, b) => a.lexical_compare(b))
  names
}

///|
/// Empty file selection means all files. Results are ordered by file then source.
pub fn Workspace::select(
  self : Workspace,
  expression : String,
  files? : Array[String] = [],
) -> Json raise {
  let query = compile_query(expression)
  let rows : Array[Json] = []
  let mut total = 0
  for name in self.selected_names(files) {
    let matches = query.select(self.documents[name].doc)
    total += matches.length()
    if total > 10000 {
      raise InvalidQuery("Workspace exceeds 10000 query matches")
    }
    if !matches.is_empty() {
      rows.push(
        Json::object({
          "file": Json::string(name),
          "matches": located_values_to_json(matches),
        }),
      )
    }
  }
  Json::array(rows)
}

///|
/// Every edit addresses original file contents. Failure returns no new workspace.
pub fn Workspace::edit_query(
  self : Workspace,
  expression : String,
  operation : QueryEdit,
  files? : Array[String] = [],
) -> Workspace raise {
  self.select(expression, files~) |> ignore
  let output = self.files()
  for name in self.selected_names(files) {
    output[name] = self.documents[name].edit_query(expression, operation).text()
  }
  new_workspace(output, options=self.options)
}

///|
pub fn query_workspace_snapshot(
  snapshot : Json,
  expression : String,
  files? : Array[String] = [],
  options? : ParseOptions = ParseOptions::default(),
) -> Json raise {
  guard snapshot is Object(fields) &&
    fields.get("format") == Some(Json::string("moonvalve-project-v1")) &&
    fields.get("source") is Some(String(source)) &&
    fields.get("files") is Some(contents) else {
    raise InvalidReference("Expected MoonValve project snapshot")
  }
  let workspace = workspace_from_json(contents, options~)
  if !workspace.documents.contains(source) {
    raise InvalidReference("Snapshot entry is missing")
  }
  workspace.select(expression, files~)
}
