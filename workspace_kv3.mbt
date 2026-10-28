///|
/// Typed queries select KV3 files only. Explicit selections reject KV1 files.
pub fn Workspace::select_kv3(
  self : Workspace,
  expression : String,
  files? : Array[String] = [],
) -> Json raise {
  let query = compile_kv3_query(expression)
  let rows : Array[Json] = []
  let mut total = 0
  for name in self.selected_names(files) {
    guard self.kv3_documents.get(name) is Some(document) else {
      if !files.is_empty() {
        raise InvalidQuery("Selected file is not KV3")
      }
      continue
    }
    let matches = query.select(document.document())
    total += matches.length()
    if total > 10000 {
      raise InvalidQuery("Workspace exceeds 10000 query matches")
    }
    if !matches.is_empty() {
      rows.push(
        Json::object({
          "file": Json::string(name),
          "matches": kv3_located_values_to_json(matches),
        }),
      )
    }
  }
  Json::array(rows)
}

///|
/// All targets use original file snapshots. Failure returns no partial workspace.
pub fn Workspace::edit_query_kv3(
  self : Workspace,
  expression : String,
  operation : KV3QueryEdit,
  files? : Array[String] = [],
) -> Workspace raise {
  self.select_kv3(expression, files~) |> ignore
  let output = self.files()
  for name in self.selected_names(files) {
    if self.kv3_documents.get(name) is Some(document) {
      output[name] = document.edit_query(expression, operation).text()
    }
  }
  new_workspace(output, options=self.options)
}

///|
pub fn query_workspace_kv3_snapshot(
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
  if !workspace.has_file(source) {
    raise InvalidReference("Snapshot entry is missing")
  }
  workspace.select_kv3(expression, files~)
}
