///|
priv struct LspReference {
  target : String
  start : Int32
  end : Int32
}

///|
fn LspServer::reference_graph(
  self : LspServer,
) -> Map[String, Array[LspReference]] raise {
  if !self.references_dirty {
    return self.reference_cache
  }
  let graph : Map[String, Array[LspReference]] = Map([])
  let mut count = 0
  for uri, document in self.documents {
    if lsp_is_kv3(uri, document.text) {
      continue
    }
    let source = self.source(uri) catch { _ => continue }
    let path = lsp_virtual_uri(uri) catch { _ => continue }
    let edges : Array[LspReference] = []
    for i in 0..<source.doc.entries.length() {
      let entry = source.doc.entries[i]
      if !entry.key.equal_ignore_ascii_case("#base") &&
        !entry.key.equal_ignore_ascii_case("#include") {
        continue
      }
      guard entry.value is Text(reference) else { continue }
      let target = child_reference(path, reference) catch { _ => continue }
      let span = source.span([i])
      count += 1
      if count > 10000 {
        raise Failure("Reference graph exceeds 10000 edges")
      }
      edges.push({ target, start: span.value_start, end: span.value_end, })
    }
    graph[path] = edges
  }
  self.reference_cache.clear()
  for path, edges in graph {
    self.reference_cache[path] = edges
  }
  self.references_dirty = false
  self.reference_cache
}

///|
fn lsp_file_uri(path : String) -> String {
  let output = StringBuilder()
  output.write_string("file://")
  let digits = "0123456789ABCDEF".to_array()
  for b in @utf8.encode(path[:]) {
    let n = b.to_int()
    if (n >= 65 && n <= 90) ||
      (n >= 97 && n <= 122) ||
      (n >= 48 && n <= 57) ||
      "-._~/:".to_array().contains(n.to_char().unwrap()) {
      output.write_char(n.to_char().unwrap())
    } else {
      output.write_char('%')
      output.write_char(digits[n / 16])
      output.write_char(digits[n % 16])
    }
  }
  output.to_string()
}

///|
fn LspServer::reference_targets(self : LspServer) -> Json raise {
  let targets : Map[String, Bool] = Map([])
  for _, edges in self.reference_graph() {
    for edge in edges {
      targets[edge.target] = true
    }
  }
  let names = targets.keys().collect()
  names.sort()
  Json::array(names.map(name => Json::string(lsp_file_uri(name))))
}

///|
fn lsp_graph_problem(
  target : String,
  graph : Map[String, Array[LspReference]],
  missing : Map[String, Bool],
  stack : Array[String],
  visited : Map[String, Bool],
  budget : Ref[Int32],
) -> (String, Array[String])? {
  if budget.val <= 0 {
    return None
  }
  budget.val -= 1
  if stack.contains(target) {
    return Some(("reference_cycle", stack + [target]))
  }
  if missing.contains(target) && !graph.contains(target) {
    return Some(("missing_reference", stack + [target]))
  }
  if visited.contains(target) {
    return None
  }
  visited[target] = true
  if graph.get(target) is Some(edges) {
    for edge in edges {
      let problem = lsp_graph_problem(
        edge.target,
        graph,
        missing,
        stack + [target],
        visited,
        budget,
      )
      if problem is Some(_) {
        return problem
      }
    }
  }
  None
}

///|
fn LspServer::reference_diagnostics(
  self : LspServer,
  uri : String,
) -> Array[Json] raise {
  let graph = self.reference_graph()
  let path = lsp_virtual_uri(uri) catch { _ => return [] }
  let source = self.source(uri)
  let errors : Array[Json] = []
  let budget = Ref::{ val: 10000, }
  // Directives are checked in every condition branch; no target platform is assumed.
  for edge in graph.get(path).unwrap_or([]) {
    if errors.length() >= 128 {
      break
    }
    if lsp_graph_problem(
        edge.target,
        graph,
        self.missing_files,
        [path],
        Map([]),
        budget,
      )
      is Some((code, chain)) {
      errors.push(
        Json::object({
          "range": lsp_range(source.source, edge.start, edge.end),
          "severity": Json::number(
            if code == "reference_cycle" {
              1
            } else {
              2
            },
          ),
          "source": Json::string("MoonValve"),
          "code": Json::string(code),
          "message": Json::string(
            (if code == "reference_cycle" {
              "Cyclic file reference: "
            } else {
              "Missing reference target (confirmed by client): "
            }) +
            chain.join(" -> "),
          ),
          "relatedInformation": Json::array(
            chain.map(name => {
              Json::object({
                "location": Json::object({
                  "uri": Json::string(lsp_file_uri(name)),
                  "range": lsp_range("", 0, 0),
                }),
                "message": Json::string(name),
              })
            }),
          ),
        }),
      )
    }
  }
  errors
}

///|
fn LspServer::publish_open_diagnostics(
  self : LspServer,
  output : Array[Json],
) -> Unit {
  for uri, document in self.documents {
    if document.opened {
      output.push(self.diagnostics(uri))
    }
  }
}

///|
fn LspServer::publish_other_diagnostics(
  self : LspServer,
  except : String,
  output : Array[Json],
) -> Unit {
  for uri, document in self.documents {
    if document.opened && uri != except {
      output.push(self.diagnostics(uri))
    }
  }
}

///|
fn lsp_moves(params : Map[String, Json]) -> Array[(String, String)] raise {
  guard params.get("files") is Some(Array(files)) && files.length() <= 64 else {
    raise Failure("Expected at most 64 renames")
  }
  let moves : Array[(String, String)] = []
  for file in files {
    guard file is Object(fields) else {
      raise Failure("Expected rename object")
    }
    let old = lsp_virtual_uri(lsp_string(fields, "oldUri"))
    let new = lsp_virtual_uri(lsp_string(fields, "newUri"))
    if old == new || new.has_prefix(old + "/") {
      raise Failure("Invalid or recursive rename")
    }
    for (from, to) in moves {
      if old == from ||
        old.has_prefix(from + "/") ||
        from.has_prefix(old + "/") ||
        new == to ||
        new.has_prefix(to + "/") ||
        to.has_prefix(new + "/") ||
        old == to ||
        new == from {
        raise Failure("Overlapping or chained rename batch")
      }
    }
    moves.push((old, new))
  }
  moves
}

///|
fn lsp_moved(path : String, moves : Array[(String, String)]) -> String {
  for (old, new) in moves {
    if path == old {
      return new
    }
    if path.has_prefix(old + "/") {
      return new + path[old.length():].to_owned()
    }
  }
  path
}

///|
fn LspServer::validate_moves(
  self : LspServer,
  moves : Array[(String, String)],
) -> Unit raise {
  let occupied : Map[String, Bool] = Map([])
  for uri, _ in self.documents {
    let path = lsp_virtual_uri(uri) catch { _ => continue }
    let next = lsp_moved(path, moves)
    if occupied.contains(next) {
      raise Failure("Rename collides with a cached file")
    }
    occupied[next] = true
  }
}

///|
fn LspServer::will_rename(
  self : LspServer,
  params : Map[String, Json],
) -> Json raise {
  let moves = lsp_moves(params)
  self.validate_moves(moves)
  let edits : Array[Json] = self.resource_rename_edits(moves)
  for uri, document in self.documents {
    if lsp_is_kv3(uri, document.text) {
      continue
    }
    let old_path = lsp_virtual_uri(uri) catch { _ => continue }
    let new_path = lsp_moved(old_path, moves)
    let source = self.source(uri) catch {
      _ => {
        if document.text.to_lower().contains("#base") ||
          document.text.to_lower().contains("#include") {
          raise Failure(
            "Cannot safely update references in malformed file: " + uri,
          )
        }
        continue
      }
    }
    let changes : Array[Change] = []
    let occurrences : Map[String, Int32] = Map([])
    for entry in source.doc.entries {
      let occurrence = occurrences.get(entry.key).unwrap_or(0)
      occurrences[entry.key] = occurrence + 1
      if !entry.key.equal_ignore_ascii_case("#base") &&
        !entry.key.equal_ignore_ascii_case("#include") {
        continue
      }
      guard entry.value is Text(reference) else {
        raise Failure("Invalid reference directive")
      }
      let target = child_reference(old_path, reference)
      let next_target = lsp_moved(target, moves)
      if next_target != target || new_path != old_path {
        changes.push({
          path: [{ key: entry.key, occurrence, }],
          operation: Replace(Text(relative_reference(new_path, next_target))),
        })
      }
    }
    if changes.is_empty() {
      continue
    }
    let result = source.apply_snapshot(changes)
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
  Json::object({ "documentChanges": Json::array(edits) })
}

///|
fn LspServer::did_rename(
  self : LspServer,
  params : Map[String, Json],
) -> Unit raise {
  let moves = lsp_moves(params)
  self.validate_moves(moves)
  let documents : Map[String, LspDocument] = Map([])
  let cache : Map[String, String] = Map([])
  for uri, document in self.documents {
    let old = lsp_virtual_uri(uri) catch {
      _ => {
        documents[uri] = document
        continue
      }
    }
    let next = lsp_moved(old, moves)
    let mut key = uri
    if next != old {
      key = lsp_file_uri(next)
      if params.get("files") is Some(Array(files)) {
        for file in files {
          guard file is Object(row) else { continue }
          let from = lsp_virtual_uri(lsp_string(row, "oldUri"))
          if old == from || old.has_prefix(from + "/") {
            key = lsp_string(row, "newUri") +
              lsp_file_uri(old[from.length():].to_owned())[7:].to_owned()
            break
          }
        }
      }
    }
    documents[key] = document
    if self.workspace_files.get(uri) is Some(text) {
      cache[key] = text
    }
  }
  self.references_dirty = true
  self.resource_states.clear()
  self.documents.clear()
  self.workspace_files.clear()
  for uri, document in documents {
    self.documents[uri] = document
  }
  for uri, text in cache {
    self.workspace_files[uri] = text
  }
}
