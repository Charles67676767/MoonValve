///|
priv struct LspDocument {
  text : String
  version : Int
  opened : Bool
}

///|
/// Transport-independent LSP 3.17 engine. Files enter only through client messages.
struct LspServer {
  documents : Map[String, LspDocument]
  workspace_files : Map[String, String]
  mut initialized : Bool
  mut shutting_down : Bool
  mut exiting : Bool
  mut literal : Bool
}

///|
pub fn new_lsp_server() -> LspServer {
  {
    documents: Map([]),
    workspace_files: Map([]),
    initialized: false,
    shutting_down: false,
    exiting: false,
    literal: false,
  }
}

///|
pub fn LspServer::should_exit(self : LspServer) -> Bool {
  self.exiting
}

///|
pub fn LspServer::exit_code(self : LspServer) -> Int {
  if self.shutting_down {
    0
  } else {
    1
  }
}

///|
fn lsp_string(fields : Map[String, Json], key : String) -> String raise {
  guard fields.get(key) is Some(String(text)) else {
    raise Failure("Expected string field " + key)
  }
  text
}

///|
fn lsp_object(
  fields : Map[String, Json],
  key : String,
) -> Map[String, Json] raise {
  guard fields.get(key) is Some(Object(object)) else {
    raise Failure("Expected object field " + key)
  }
  object
}

///|
fn lsp_int(fields : Map[String, Json], key : String) -> Int raise {
  guard fields.get(key) is Some(Number(n, ..)) &&
    n >= -2147483648.0 &&
    n <= 2147483647.0 &&
    n == n.to_int().to_double() else {
    raise Failure("Expected integer " + key)
  }
  n.to_int()
}

///|
pub fn lsp_position(text : String, offset : Int) -> Json {
  let chars = text.to_array()
  let mut line = 0
  let mut column = 0
  for i in 0..<offset.min(chars.length()).max(0) {
    let c = chars[i]
    if c == '\r' {
      line += 1
      column = 0
    } else if c == '\n' {
      if i == 0 || chars[i - 1] != '\r' {
        line += 1
      }
      column = 0
    } else {
      column += if c.to_int() > 65535 { 2 } else { 1 }
    }
  }
  Json::object({
    "line": Json::number(line.to_double()),
    "character": Json::number(column.to_double()),
  })
}

///|
fn lsp_offset(text : String, position : Map[String, Json]) -> Int raise {
  let wanted_line = lsp_int(position, "line")
  let wanted_column = lsp_int(position, "character")
  if wanted_line < 0 || wanted_column < 0 {
    raise Failure("Negative LSP position")
  }
  let chars = text.to_array()
  let mut line = 0
  let mut column = 0
  let mut i = 0
  while i <= chars.length() {
    if line == wanted_line && column == wanted_column {
      return i
    }
    if i == chars.length() {
      break
    }
    let c = chars[i]
    if c == '\r' || c == '\n' {
      if line == wanted_line {
        raise Failure("Position exceeds line length")
      }
      if c == '\r' && chars.get(i + 1) == Some('\n') {
        i += 1
      }
      line += 1
      column = 0
    } else {
      column += if c.to_int() > 65535 { 2 } else { 1 }
      if line == wanted_line && column > wanted_column {
        raise Failure("Position splits a Unicode surrogate pair")
      }
    }
    i += 1
  }
  raise Failure("Position exceeds document")
}

///|
fn lsp_range(text : String, start : Int, end : Int) -> Json {
  Json::object({
    "start": lsp_position(text, start),
    "end": lsp_position(text, end),
  })
}

///|
fn lsp_virtual_uri(uri : String) -> String raise {
  if !uri.has_prefix("file://") {
    raise Failure("References require file:// URIs")
  }
  let raw = uri[7:].to_owned()
  let chars = raw.to_array()
  let output = @buffer.Buffer()
  let mut i = 0
  while i < chars.length() {
    if chars[i] == '%' {
      guard i + 2 < chars.length() &&
        kv3_hex(chars[i + 1]) is Some(a) &&
        kv3_hex(chars[i + 2]) is Some(b) else {
        raise Failure("Invalid URI encoding")
      }
      output.write_byte((a * 16 + b).to_byte())
      i += 3
    } else {
      output.write_bytes(@utf8.encode(chars[i].to_string()[:])[:])
      i += 1
    }
  }
  let decoded = @utf8.decode(output.to_bytes()[:])
  if decoded.contains("\u0000") {
    raise Failure("NUL in URI")
  }
  normalize_reference(decoded)
}

///|
fn LspServer::put(
  self : LspServer,
  uri : String,
  document : LspDocument,
) -> Unit raise {
  if uri.length() > 32768 || uri.contains("\u0000") {
    raise Failure("Invalid document URI")
  }
  if !self.documents.contains(uri) && self.documents.length() >= 64 {
    raise Failure("Workspace exceeds 64 documents")
  }
  let mut total = document.text.char_length()
  for name, previous in self.documents {
    if name != uri {
      total += previous.text.char_length()
    }
  }
  if total > 16777216 || document.text.char_length() > 8388608 {
    raise Failure("LSP document character budget exceeded")
  }
  self.documents[uri] = document
}

///|
fn lsp_is_kv3(uri : String, text : String) -> Bool {
  uri.to_lower().has_suffix(".kv3") ||
  text.trim_start().to_owned().has_prefix("<!-- kv3")
}

///|
fn LspServer::source(self : LspServer, uri : String) -> SourceDocument raise {
  guard self.documents.get(uri) is Some(document) else {
    raise Failure("Document is not available")
  }
  if lsp_is_kv3(uri, document.text) {
    raise Failure("This navigation feature applies to KV1")
  }
  parse_preserving(document.text, options={
    ..ParseOptions::default(),
    escape_sequences: !self.literal,
  })
}

///|
fn lsp_notification(rpc_method : String, params : Json) -> Json {
  Json::object({
    "jsonrpc": Json::string("2.0"),
    "method": Json::string(rpc_method),
    "params": params,
  })
}

///|
fn LspServer::diagnostics(self : LspServer, uri : String) -> Json {
  let errors : Array[Json] = []
  let version = match self.documents.get(uri) {
    None => None
    Some(document) => {
      try {
        if lsp_is_kv3(uri, document.text) {
          parse_kv3(document.text) |> ignore
        } else {
          self.source(uri) |> ignore
        }
      } catch {
        ParseError(d) =>
          errors.push(
            Json::object({
              "range": lsp_range(
                document.text,
                d.offset,
                (d.offset + 1).min(document.text.char_length()),
              ),
              "severity": Json::number(1),
              "code": Json::string(d.code),
              "source": Json::string("MoonValve"),
              "message": Json::string(d.message),
            }),
          )
        error =>
          errors.push(
            Json::object({
              "range": lsp_range(document.text, 0, 0),
              "severity": Json::number(1),
              "source": Json::string("MoonValve"),
              "message": Json::string(error.to_string()),
            }),
          )
      }
      if document.opened {
        Some(document.version)
      } else {
        None
      }
    }
  }
  let params : Map[String, Json] = {
    "uri": Json::string(uri),
    "diagnostics": Json::array(errors),
  }
  if version is Some(v) {
    params["version"] = Json::number(v.to_double())
  }
  lsp_notification("textDocument/publishDiagnostics", Json::object(params))
}

///|
fn lsp_symbols(
  source : SourceDocument,
  entries : Array[Entry],
  path : Array[Int],
  coordinates : LspCoordinates,
  budget : Ref[Int],
) -> Array[Json] raise {
  let rows : Array[Json] = []
  for i in 0..<entries.length() {
    if budget.val <= 0 {
      break
    }
    budget.val -= 1
    let entry = entries[i]
    let next = [..path, i]
    let span = source.span(next)
    let children = match entry.value {
      Object(entries) => lsp_symbols(source, entries, next, coordinates, budget)
      _ => []
    }
    rows.push(
      Json::object({
        "name": Json::string(
          if entry.key == "" {
            "(empty key)"
          } else {
            entry.key
          },
        ),
        "kind": Json::number(if entry.value is Object(_) { 19 } else { 15 }),
        "range": coordinates.range(span.key_start, span.entry_end),
        "selectionRange": coordinates.range(span.key_start, span.key_end),
        "children": Json::array(children),
      }),
    )
  }
  rows
}

///|
fn LspServer::target_uri(
  self : LspServer,
  source : String,
  reference : String,
) -> String? raise {
  let target = child_reference(lsp_virtual_uri(source), reference)
  for uri, _ in self.documents {
    let path = lsp_virtual_uri(uri) catch { _ => continue }
    if path == target {
      return Some(uri)
    }
  }
  None
}

///|
fn LspServer::reference_at(
  self : LspServer,
  uri : String,
  offset : Int,
) -> (SourceDocument, SourceSpan, String)? raise {
  let source = self.source(uri)
  for i in 0..<source.doc.entries.length() {
    let entry = source.doc.entries[i]
    if entry.key.equal_ignore_ascii_case("#include") ||
      entry.key.equal_ignore_ascii_case("#base") {
      let span = source.span([i])
      if offset >= span.key_start &&
        offset <= span.entry_end &&
        entry.value is Text(reference) {
        return Some((source, span, reference))
      }
    }
  }
  None
}

///|
fn LspServer::perform(
  self : LspServer,
  rpc_method : String,
  params : Map[String, Json],
  output : Array[Json],
) -> Json raise {
  if rpc_method == "initialize" {
    if self.initialized {
      raise Failure("Server is already initialized")
    }
    self.initialized = true
    if params.get("initializationOptions") is Some(Object(options)) {
      self.literal = options.get("literalPaths") == Some(Json::boolean(true))
    }
    return Json::object({
      "capabilities": Json::object({
        "positionEncoding": Json::string("utf-16"),
        "textDocumentSync": Json::object({
          "openClose": Json::boolean(true),
          "change": Json::number(2),
        }),
        "documentSymbolProvider": Json::boolean(true),
        "foldingRangeProvider": Json::boolean(true),
        "definitionProvider": Json::boolean(true),
        "hoverProvider": Json::boolean(true),
        "documentFormattingProvider": Json::boolean(true),
        "documentLinkProvider": Json::object({}),
        "completionProvider": Json::object({
          "triggerCharacters": Json::array([
            Json::string("\""),
            Json::string("/"),
          ]),
        }),
      }),
      "serverInfo": Json::object({
        "name": Json::string("MoonValve"),
        "version": Json::string(version()),
      }),
    })
  }
  if rpc_method == "exit" {
    self.exiting = true
    return Json::null()
  }
  if !self.initialized {
    raise Failure("Server is not initialized")
  }
  if rpc_method == "shutdown" {
    self.shutting_down = true
    return Json::null()
  }
  if self.shutting_down {
    raise Failure("Server has shut down")
  }
  if [
      "textDocument/definition", "textDocument/foldingRange", "textDocument/documentLink",
      "textDocument/completion", "textDocument/hover",
    ].contains(rpc_method) {
    let uri = lsp_string(lsp_object(params, "textDocument"), "uri")
    if self.documents.get(uri) is Some(document) &&
      lsp_is_kv3(uri, document.text) {
      return if rpc_method == "textDocument/hover" {
        Json::null()
      } else {
        Json::array([])
      }
    }
  }
  match rpc_method {
    "initialized" | "$/cancelRequest" => Json::null()
    "moonvalve/setFile" => {
      let uri = lsp_string(params, "uri")
      let text = lsp_string(params, "text")
      let mut cache_size = text.char_length()
      for name, cached in self.workspace_files {
        if name != uri {
          cache_size += cached.char_length()
        }
      }
      if cache_size > 16777216 {
        raise Failure("Workspace cache exceeds character budget")
      }
      if self.documents.get(uri) is Some(previous) && previous.opened {
        if text.char_length() > 8388608 {
          raise Failure("Cached file exceeds budget")
        }
      } else {
        self.put(uri, { text, version: 0, opened: false, })
      }
      self.workspace_files[uri] = text
      Json::null()
    }
    "textDocument/didOpen" => {
      let document = lsp_object(params, "textDocument")
      let uri = lsp_string(document, "uri")
      self.put(uri, {
        text: lsp_string(document, "text"),
        version: lsp_int(document, "version"),
        opened: true,
      })
      output.push(self.diagnostics(uri))
      Json::null()
    }
    "textDocument/didChange" => {
      let document = lsp_object(params, "textDocument")
      let uri = lsp_string(document, "uri")
      guard self.documents.get(uri) is Some(previous) && previous.opened else {
        raise Failure("Change requires an open document")
      }
      let version = lsp_int(document, "version")
      if version <= previous.version {
        return Json::null()
      }
      guard params.get("contentChanges") is Some(Array(changes)) &&
        changes.length() <= 1000 else {
        raise Failure("Invalid document changes")
      }
      let mut text = previous.text
      for change in changes {
        guard change is Object(fields) else {
          raise Failure("Invalid content change")
        }
        let replacement = lsp_string(fields, "text")
        text = if fields.get("range") is Some(Object(range)) {
          let start = lsp_offset(text, lsp_object(range, "start"))
          let end = lsp_offset(text, lsp_object(range, "end"))
          if end < start {
            raise Failure("Reversed edit range")
          }
          let chars = text.to_array()
          String::from_array(chars[:start].to_owned()) +
          replacement +
          String::from_array(chars[end:].to_owned())
        } else {
          replacement
        }
        if text.char_length() > 8388608 {
          raise Failure("Edited document exceeds budget")
        }
      }
      self.put(uri, { text, version, opened: true, })
      output.push(self.diagnostics(uri))
      Json::null()
    }
    "textDocument/didClose" => {
      let uri = lsp_string(lsp_object(params, "textDocument"), "uri")
      match self.workspace_files.get(uri) {
        Some(text) => self.documents[uri] = { text, version: 0, opened: false, }
        None => self.documents.remove(uri) |> ignore
      }
      output.push(
        lsp_notification(
          "textDocument/publishDiagnostics",
          Json::object({
            "uri": Json::string(uri),
            "diagnostics": Json::array([]),
          }),
        ),
      )
      Json::null()
    }
    "moonvalve/removeFile" => {
      let uri = lsp_string(params, "uri")
      self.workspace_files.remove(uri) |> ignore
      if self.documents.get(uri) is Some(document) && !document.opened {
        self.documents.remove(uri) |> ignore
      }
      Json::null()
    }
    "textDocument/documentSymbol" => {
      let uri = lsp_string(lsp_object(params, "textDocument"), "uri")
      let symbols = try {
        let source = self.source(uri)
        lsp_symbols(
          source,
          source.doc.entries,
          [],
          lsp_coordinates(source.source),
          { val: 5000, },
        )
      } catch {
        _ => []
      }
      Json::array(symbols)
    }
    "textDocument/foldingRange" => {
      let uri = lsp_string(lsp_object(params, "textDocument"), "uri")
      let source = self.source(uri)
      let coordinates = lsp_coordinates(source.source)
      let ranges : Array[Json] = []
      for span in source.spans {
        if source.chars[span.value_start] == '{' {
          guard coordinates.position(span.value_start) is Object(start) &&
            coordinates.position(span.value_end - 1) is Object(end) else {
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
      }
      Json::array(ranges)
    }
    "textDocument/definition" => {
      let uri = lsp_string(lsp_object(params, "textDocument"), "uri")
      guard self.documents.get(uri) is Some(document) else {
        raise Failure("Document missing")
      }
      let offset = lsp_offset(document.text, lsp_object(params, "position"))
      if self.reference_at(uri, offset) is Some((_, _, path)) &&
        self.target_uri(uri, path) is Some(target) {
        Json::array([
          Json::object({
            "uri": Json::string(target),
            "range": lsp_range("", 0, 0),
          }),
        ])
      } else {
        Json::array([])
      }
    }
    "textDocument/documentLink" => {
      let uri = lsp_string(lsp_object(params, "textDocument"), "uri")
      let source = self.source(uri)
      let links : Array[Json] = []
      for i in 0..<source.doc.entries.length() {
        let entry = source.doc.entries[i]
        if (
            entry.key.equal_ignore_ascii_case("#include") ||
            entry.key.equal_ignore_ascii_case("#base")
          ) &&
          entry.value is Text(path) &&
          self.target_uri(uri, path) is Some(target) {
          let span = source.span([i])
          links.push(
            Json::object({
              "range": lsp_range(
                source.source,
                span.value_start,
                span.value_end,
              ),
              "target": Json::string(target),
            }),
          )
        }
      }
      Json::array(links)
    }
    "textDocument/completion" => {
      let uri = lsp_string(lsp_object(params, "textDocument"), "uri")
      guard self.documents.get(uri) is Some(document) else {
        raise Failure("Document missing")
      }
      let offset = lsp_offset(document.text, lsp_object(params, "position"))
      let items : Array[Json] = []
      if self.reference_at(uri, offset) is Some((source, span, _)) {
        let origin = lsp_virtual_uri(uri)
        for target, _ in self.documents {
          if target == uri {
            continue
          }
          let target_path = lsp_virtual_uri(target) catch { _ => continue }
          let path = relative_reference(origin, target_path)
          let value = StringBuilder()
          source.render_string(value, path, true)
          items.push(
            Json::object({
              "label": Json::string(path),
              "kind": Json::number(17),
              "textEdit": Json::object({
                "range": lsp_range(
                  document.text,
                  span.value_start,
                  span.value_end,
                ),
                "newText": Json::string(value.to_string()),
              }),
            }),
          )
        }
      } else {
        let source = self.source(uri)
        let keys : Map[String, Bool] = { "#include": true, "#base": true }
        source.doc.walk((path, _) => {
          if keys.length() < 2000 {
            keys[path[path.length() - 1].key] = true
          }
          true
        })
        let names = keys.keys().collect()
        names.sort()
        for name in names {
          let insertion = StringBuilder()
          source.render_string(
            insertion,
            name,
            !kv3_identifier(name) && name != "#include" && name != "#base",
          )
          items.push(
            Json::object({
              "label": Json::string(name),
              "kind": Json::number(5),
              "insertText": Json::string(insertion.to_string()),
            }),
          )
        }
      }
      Json::array(items)
    }
    "textDocument/hover" => {
      let uri = lsp_string(lsp_object(params, "textDocument"), "uri")
      let source = self.source(uri)
      let offset = lsp_offset(source.source, lsp_object(params, "position"))
      for span in source.spans {
        if offset >= span.key_start && offset < span.key_end {
          let key = String::from_array(
            source.chars[span.key_start:span.key_end].to_owned(),
          )
          return Json::object({
            "contents": Json::object({
              "kind": Json::string("plaintext"),
              "value": Json::string(
                "KeyValues key: " +
                key +
                "\nMoonValve preserves order and duplicate occurrences.",
              ),
            }),
            "range": lsp_range(source.source, span.key_start, span.key_end),
          })
        }
      }
      Json::null()
    }
    "textDocument/formatting" => {
      let uri = lsp_string(lsp_object(params, "textDocument"), "uri")
      guard self.documents.get(uri) is Some(document) else {
        raise Failure("Document missing")
      }
      let text = if lsp_is_kv3(uri, document.text) {
        stringify_kv3(parse_kv3(document.text))
      } else {
        let source = self.source(uri)
        let conditional : Ref[Bool] = { val: false, }
        let parser = new_stream_parser(
          event => {
            if event is Condition(_, _) {
              conditional.val = true
            }
            true
          },
          options={
            ..ParseOptions::default(),
            escape_sequences: !self.literal,
          },
        )
        parser.feed(document.text)
        parser.finish()
        if conditional.val {
          raise Failure(
            "Formatting unresolved conditions would change semantics; use source edits",
          )
        }
        stringify(source.doc)
      }
      Json::array([
        Json::object({
          "range": lsp_range(document.text, 0, document.text.char_length()),
          "newText": Json::string(text),
        }),
      ])
    }
    _ => raise Failure("Unknown method: " + rpc_method)
  }
}

///|
priv struct LspCoordinates {
  starts : Array[Int]
  units : Array[Int]
}

///|
fn lsp_coordinates(text : String) -> LspCoordinates {
  let chars = text.to_array()
  let starts = [0]
  let units = [0]
  for i in 0..<chars.length() {
    let c = chars[i]
    units.push(
      units[units.length() - 1] + (if c.to_int() > 65535 { 2 } else { 1 }),
    )
    if c == '\r' {
      starts.push(i + 1)
    } else if c == '\n' {
      if i > 0 && chars[i - 1] == '\r' {
        starts[starts.length() - 1] = i + 1
      } else {
        starts.push(i + 1)
      }
    }
  }
  { starts, units, }
}

///|
fn LspCoordinates::position(self : LspCoordinates, offset : Int) -> Json {
  let point = offset.max(0).min(self.units.length() - 1)
  let mut low = 0
  let mut high = self.starts.length()
  while low + 1 < high {
    let mid = (low + high) / 2
    if self.starts[mid] <= point {
      low = mid
    } else {
      high = mid
    }
  }
  Json::object({
    "line": Json::number(low.to_double()),
    "character": Json::number(
      (self.units[point] - self.units[self.starts[low]]).to_double(),
    ),
  })
}

///|
fn LspCoordinates::range(self : LspCoordinates, start : Int, end : Int) -> Json {
  Json::object({ "start": self.position(start), "end": self.position(end) })
}

///|
pub fn LspServer::handle(self : LspServer, request : Json) -> Array[Json] {
  let output : Array[Json] = []
  guard request is Object(fields) &&
    fields.get("jsonrpc") == Some(Json::string("2.0")) &&
    fields.get("method") is Some(String(rpc_method)) else {
    return [
      Json::object({
        "jsonrpc": Json::string("2.0"),
        "id": Json::null(),
        "error": Json::object({
          "code": Json::number(-32600),
          "message": Json::string("Invalid JSON-RPC request"),
        }),
      }),
    ]
  }
  let id = fields.get("id")
  try {
    let params = match fields.get("params") {
      None => Map([])
      Some(Object(p)) => p
      _ => raise Failure("Expected object parameters")
    }
    let result = self.perform(rpc_method, params, output)
    if id is Some(id) {
      output.push(
        Json::object({
          "jsonrpc": Json::string("2.0"),
          "id": id,
          "result": result,
        }),
      )
    }
  } catch {
    error => {
      let message = error.to_string()
      if id is Some(id) {
        output.push(
          Json::object({
            "jsonrpc": Json::string("2.0"),
            "id": id,
            "error": Json::object({
              "code": Json::number(
                if message.contains("Unknown method:") {
                  -32601
                } else {
                  -32602
                },
              ),
              "message": Json::string(message),
            }),
          }),
        )
      } else {
        output.push(
          lsp_notification(
            "window/logMessage",
            Json::object({
              "type": Json::number(1),
              "message": Json::string(message),
            }),
          ),
        )
      }
    }
  }
  output
}
