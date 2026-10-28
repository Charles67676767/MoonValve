///|
fn LspServer::resource_references(self : LspServer) -> Json raise {
  let rows : Array[Json] = []
  let names = self.documents.keys().collect()
  names.sort()
  for uri in names {
    let document = self.documents[uri]
    if !lsp_is_kv3(uri, document.text) {
      continue
    }
    let source = parse_kv3_preserving(document.text) catch { _ => continue }
    for reference in source.resources(roots=self.resource_roots) {
      if rows.length() >= 10000 {
        raise Failure("Resource workspace exceeds 10000 references")
      }
      let target = reference.target.map(path => lsp_file_uri(path))
      rows.push(
        Json::object({
          "uri": Json::string(uri),
          "range": lsp_range(document.text, reference.start, reference.end),
          "resource": Json::string(reference.resource),
          "target": match target {
            Some(t) => Json::string(t)
            None => Json::null()
          },
          "status": Json::string(
            match reference.target {
              Some(path) =>
                self.resource_states.get(path).unwrap_or("unchecked")
              None => reference.status
            },
          ),
        }),
      )
    }
  }
  Json::array(rows)
}

///|
fn LspServer::resource_targets(self : LspServer) -> Json raise {
  let targets : Map[String, Bool] = Map([])
  guard self.resource_references() is Array(rows) else {
    return Json::array([])
  }
  for row in rows {
    if row is Object(fields) && fields.get("target") is Some(String(target)) {
      targets[target] = true
    }
  }
  let names = targets.keys().collect()
  names.sort()
  Json::array(names.map(s => Json::string(s)))
}

///|
fn LspServer::resource_diagnostics(
  self : LspServer,
  uri : String,
) -> Array[Json] raise {
  let document = self.documents[uri]
  let source = parse_kv3_preserving(document.text)
  let rows : Array[Json] = []
  for reference in source.resources(roots=self.resource_roots) {
    let state = match reference.target {
      Some(path) => self.resource_states.get(path).unwrap_or("unchecked")
      None => reference.status
    }
    if state != "missing" && state != "invalid" {
      continue
    }
    rows.push(
      Json::object({
        "range": lsp_range(document.text, reference.start, reference.end),
        "severity": Json::number(2),
        "code": Json::string(
          if state == "missing" {
            "missing_resource"
          } else {
            "invalid_resource_path"
          },
        ),
        "source": Json::string("MoonValve"),
        "message": Json::string(
          if state == "missing" {
            "Resource file confirmed missing: " + reference.resource
          } else {
            "Resource path must be a normalized relative file path: " +
            reference.resource
          },
        ),
      }),
    )
    if rows.length() >= 128 {
      break
    }
  }
  rows
}

///|
fn LspServer::resource_links(
  self : LspServer,
  uri : String,
  offset : Int?,
) -> Json raise {
  let document = self.documents[uri]
  let source = parse_kv3_preserving(document.text)
  let rows : Array[Json] = []
  for reference in source.resources(roots=self.resource_roots) {
    guard reference.target is Some(target) else { continue }
    if self.resource_states.get(target) != Some("present") {
      continue
    }
    if offset is Some(at) {
      if at >= reference.start && at < reference.end {
        rows.push(
          Json::object({
            "uri": Json::string(lsp_file_uri(target)),
            "range": lsp_range("", 0, 0),
          }),
        )
      }
    } else {
      rows.push(
        Json::object({
          "target": Json::string(lsp_file_uri(target)),
          "range": lsp_range(document.text, reference.start, reference.end),
        }),
      )
    }
  }
  Json::array(rows)
}

///|
fn LspServer::resource_rename_edits(
  self : LspServer,
  moves : Array[(String, String)],
) -> Array[Json] raise {
  if self.resource_roots.is_empty() {
    return []
  }
  let relevant = moves.filter(pair => {
    let (from, to) = pair
    self.resource_roots.any(root => {
      from.has_prefix(root.directory + "/") ||
      to.has_prefix(root.directory + "/") ||
      from == root.directory ||
      root.directory.has_prefix(from + "/")
    })
  })
  if relevant.is_empty() {
    return []
  }
  // Changing a configured root itself requires an explicit setting update.
  for (from, _) in relevant {
    if self.resource_roots.any(root => {
        root.directory == from || root.directory.has_prefix(from + "/")
      }) {
      raise Failure(
        "Moving a configured resource root requires updating resourceRoots first",
      )
    }
  }
  let moves : Map[String, String] = Map([])
  for (from, to) in relevant {
    moves[from] = to
  }
  let edits : Array[Json] = []
  for uri, document in self.documents {
    if !lsp_is_kv3(uri, document.text) {
      continue
    }
    let source = parse_kv3_preserving(document.text) catch {
      _ =>
        raise Failure(
          "Cannot update resource references in malformed KV3: " + uri,
        )
    }
    let result = source.rewrite_resources(self.resource_roots, moves)
    if result.text() == document.text {
      continue
    }
    edits.push(
      Json::object({
        "textDocument": Json::object({
          "uri": Json::string(uri),
          "version": if document.opened {
            Json::number(document.version.to_double())
          } else {
            Json::null()
          },
        }),
        "edits": Json::array([
          Json::object({
            "range": lsp_range(document.text, 0, document.text.char_length()),
            "newText": Json::string(result.text()),
          }),
        ]),
      }),
    )
  }
  edits
}
