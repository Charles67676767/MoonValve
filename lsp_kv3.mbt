///|
fn kv3_symbol_kind(value : KV3Value) -> Int {
  match kv3_unflag(value) {
    KV3Object(_) => 19
    KV3Array(_) => 18
    KV3String(_) => 15
    KV3Integer(_) | KV3Float(_) => 16
    KV3Bool(_) => 17
    KV3Null => 21
    _ => 13
  }
}

///|
fn kv3_summary(value : KV3Value) -> String {
  let prefix = match value {
    KV3Flag(flag, _) => flag + ": "
    _ => ""
  }
  let text = match kv3_unflag(value) {
    KV3Object(entries) => "object (" + entries.length().to_string() + " fields)"
    KV3Array(values) => "array (" + values.length().to_string() + " elements)"
    KV3Blob(bytes) => "blob (" + bytes.length().to_string() + " bytes)"
    KV3String(s) =>
      "string: " +
      (if s.length() > 160 { s[:160].to_owned() + "..." } else { s })
    KV3Integer(n) => "integer: " + n
    KV3Float(n) =>
      "float: " +
      (if n.length() > 160 { n[:160].to_owned() + "..." } else { n })
    KV3Bool(b) => "bool: " + b.to_string()
    _ => "null"
  }
  prefix + text
}

///|
fn lsp_kv3_symbol(
  source : KV3SourceDocument,
  value : KV3Value,
  path : Array[Int],
  name : String,
  coordinates : LspCoordinates,
  budget : Ref[Int],
) -> Json {
  budget.val -= 1
  let span = source.spans[index_key(path)]
  let container = kv3_unflag(value) is KV3Object(_) ||
    kv3_unflag(value) is KV3Array(_)
  let (start, end) = source.keys
    .get(index_key(path))
    .unwrap_or(
      (
        if container {
          span.body
        } else {
          span.start
        },
        if container {
          span.body + 1
        } else {
          span.end
        },
      ),
    )
  let children : Array[Json] = []
  match kv3_unflag(value) {
    KV3Object(entries) =>
      for i in 0..<entries.length() {
        if budget.val <= 0 {
          break
        }
        children.push(
          lsp_kv3_symbol(
            source,
            entries[i].value,
            path + [i],
            entries[i].key,
            coordinates,
            budget,
          ),
        )
      }
    KV3Array(values) =>
      for i in 0..<values.length() {
        if budget.val <= 0 {
          break
        }
        children.push(
          lsp_kv3_symbol(
            source,
            values[i],
            path + [i],
            "[" + i.to_string() + "]",
            coordinates,
            budget,
          ),
        )
      }
    _ => ()
  }
  Json::object({
    "name": Json::string(if name.is_empty() { "(empty key)" } else { name }),
    "detail": Json::string(kv3_summary(value)),
    "kind": Json::number(kv3_symbol_kind(value).to_double()),
    "range": coordinates.range(start, span.end),
    "selectionRange": coordinates.range(start, end),
    "children": Json::array(children),
  })
}

///|
fn kv3_path_names(root : KV3Value, indices : Array[Int]) -> Array[String] {
  let names : Array[String] = []
  let mut value = root
  for i in indices {
    match kv3_unflag(value) {
      KV3Object(entries) => {
        names.push(entries[i].key)
        value = entries[i].value
      }
      KV3Array(values) => {
        names.push(i.to_string())
        value = values[i]
      }
      _ => ()
    }
  }
  names
}

///|
fn LspServer::kv3_navigation(
  self : LspServer,
  rpc_method : String,
  params : Map[String, Json],
) -> Json raise {
  let uri = lsp_string(lsp_object(params, "textDocument"), "uri")
  let document = self.documents[uri]
  let source = parse_kv3_preserving(document.text)
  let coordinates = lsp_coordinates(document.text)
  match rpc_method {
    "textDocument/definition" =>
      self.resource_links(
        uri,
        Some(lsp_offset(document.text, lsp_object(params, "position"))),
      )
    "textDocument/documentLink" => self.resource_links(uri, None)
    "textDocument/documentSymbol" =>
      Json::array([
        lsp_kv3_symbol(source, source.doc.root, [], "KV3", coordinates, {
          val: 5000,
        }),
      ])
    "textDocument/foldingRange" => {
      let spans = source.spans.values().collect()
      spans.sort_by((a, b) => a.body.compare(b.body))
      let ranges : Array[Json] = []
      for span in spans {
        if source.chars[span.body] != '{' && source.chars[span.body] != '[' {
          continue
        }
        guard coordinates.position(span.body) is Object(start) &&
          coordinates.position(span.end - 1) is Object(end) else {
          continue
        }
        let first = lsp_int(start, "line")
        let last = lsp_int(end, "line") - 1
        if last > first {
          ranges.push(
            Json::object({
              "startLine": Json::number(first.to_double()),
              "endLine": Json::number(last.to_double()),
              "kind": Json::string("region"),
            }),
          )
        }
        if ranges.length() >= 5000 {
          break
        }
      }
      Json::array(ranges)
    }
    "textDocument/completion" =>
      Json::array(
        [
          "true", "false", "null", "resource:\"\"", "resource_name:\"\"", "panorama:\"\"",
          "soundevent:\"\"", "subclass:\"\"", "entity_name:\"\"", "localize:\"\"",
        ].map(label => {
          Json::object({
            "label": Json::string(label),
            "kind": Json::number(14),
            "insertText": Json::string(label),
          })
        }),
      )
    "textDocument/hover" => {
      let offset = lsp_offset(document.text, lsp_object(params, "position"))
      let mut chosen : String? = None
      let mut width = document.text.char_length() + 1
      for key, span in source.spans {
        let (start, end) = source.keys
          .get(key)
          .unwrap_or((span.start, span.end))
        if (
            (offset >= span.start && offset < span.end) ||
            (offset >= start && offset < end)
          ) &&
          span.end - start < width {
          chosen = Some(key)
          width = span.end - start
        }
      }
      guard chosen is Some(key) else { return Json::null() }
      let indices : Array[Int] = if key.is_empty() {
        []
      } else {
        key
        .split("/")
        .map(s => s.to_owned())
        .collect()
        .map(s => @strconv.parse_int(s[:]))
      }
      let value = kv3_at(source.doc.root, indices)
      let span = source.spans[key]
      let (start, end) = source.keys.get(key).unwrap_or((span.start, span.end))
      let mut resource_detail = ""
      if value is KV3Flag("resource", KV3String(_)) {
        for reference in source.resources(roots=self.resource_roots) {
          if reference.start == span.start {
            resource_detail = "\nResource: " +
              (match reference.target {
                Some(path) =>
                  self.resource_states.get(path).unwrap_or("unchecked") +
                  "\n" +
                  path
                None => reference.status
              })
            break
          }
        }
      }
      Json::object({
        "contents": Json::object({
          "kind": Json::string("plaintext"),
          "value": Json::string(
            "KV3 path: " +
            Json::array(
              kv3_path_names(source.doc.root, indices).map(s => Json::string(s)),
            ).stringify() +
            "\n" +
            kv3_summary(value) +
            resource_detail,
          ),
        }),
        "range": coordinates.range(start, end),
      })
    }
    _ => Json::array([])
  }
}
