///|
fn field(fields : Map[String, Json], key : String) -> String raise {
  guard fields.get(key) is Some(String(text)) else {
    raise Failure("Expected text field: " + key)
  }
  text
}

///|
fn execute(request : Json) -> Json raise {
  guard request is Object(fields) else {
    raise Failure("Expected a request object")
  }
  let action = field(fields, "action")
  let literal = fields.get("literal") == Some(Json::boolean(true))
  let options = {
    ..@valve.ParseOptions::default(),
    escape_sequences: !literal,
  }
  match action {
    "query" | "query-edit" => {
      let source = @valve.parse_preserving(field(fields, "text"), options~)
      let expression = field(fields, "expression")
      let matches = @valve.located_values_to_json(
        source.document().select(expression),
      )
      if action == "query" {
        Json::object({ "matches": matches })
      } else {
        guard fields.get("operation") is Some(operation) else {
          raise Failure("Expected query edit operation")
        }
        let result = source.edit_query(
          expression,
          @valve.query_edit_from_json(operation),
        )
        Json::object({
          "matches": matches,
          "text": Json::string(result.text()),
          "tree": result.document().to_json(),
        })
      }
    }
    "transfer" => {
      guard fields.get("plan") is Some(plan) else {
        raise Failure("Expected transfer plan")
      }
      let source = @valve.parse_preserving(field(fields, "text"), options~)
      let result = source.transfer_json(plan)
      Json::object({
        "text": Json::string(result.text()),
        "tree": result.document().to_json(),
      })
    }
    "workspace-edit" => {
      guard fields.get("snapshot") is Some(snapshot) &&
        fields.get("plan") is Some(plan) else {
        raise Failure("Expected workspace snapshot and plan")
      }
      @valve.edit_workspace_snapshot(snapshot, plan, options~)
    }
    "kv3-parse" | "kv3-format" => {
      let document = @valve.parse_kv3(
        field(fields, "text"),
        allow_headerless=fields.get("headerless") == Some(Json::boolean(true)),
      )
      Json::object({
        "model": @valve.kv3_to_json(document),
        "text": Json::string(@valve.stringify_kv3(document)),
      })
    }
    "kv3-from-json" => {
      guard fields.get("model") is Some(model) else {
        raise Failure("Expected typed KV3 model")
      }
      let document = @valve.kv3_from_json(model)
      Json::object({
        "model": @valve.kv3_to_json(document),
        "text": Json::string(@valve.stringify_kv3(document)),
      })
    }
    "cache-page" => cache_page(fields)
    "cache-read" => cache_record(fields)
    "cache-close" => {
      browser_cache.val = None
      Json::null()
    }
    "shortcuts-new" | "shortcuts-list" | "shortcuts-edit" =>
      shortcut_tools(action, fields)
    "project" => {
      guard fields.get("files") is Some(Object(files)) else {
        raise Failure("Expected project files")
      }
      let symbols = match fields.get("symbols") {
        Some(Array(values)) =>
          values.map(v => {
            match v {
              String(s) => s
              _ => raise Failure("Symbols must be strings")
            }
          })
        _ => []
      }
      let project = @valve.load_project(
        field(fields, "source"),
        path => {
          match files.get(path) {
            Some(String(s)) => s
            _ => raise Failure("Missing virtual file: " + path)
          }
        },
        options={ ..options, conditions: Some(symbols), },
      )
      project.to_json()
    }
    "parse" => {
      let source = @valve.parse_preserving(field(fields, "text"), options~)
      let name = match fields.get("source") {
        Some(String(s)) => s
        _ => ""
      }
      Json::object({
        "tree": source.document().to_json(),
        "text": Json::string(source.text()),
        "origins": Json::array(
          source
          .locations(name)
          .map(o => {
            Json::object({
              "path": Json::array(
                o.path.map(p => {
                  Json::object({
                    "key": Json::string(p.key),
                    "occurrence": Json::number(p.occurrence.to_double()),
                  })
                }),
              ),
              "offset": Json::number(o.location.offset.to_double()),
              "line": Json::number(o.location.line.to_double()),
              "column": Json::number(o.location.column.to_double()),
            })
          }),
        ),
      })
    }
    "evaluate" => {
      let symbols = match fields.get("symbols") {
        Some(Array(values)) =>
          values.map(value => {
            match value {
              String(s) => s
              _ => raise Failure("Symbols must be strings")
            }
          })
        _ => []
      }
      let evaluated_options = { ..options, conditions: Some(symbols), }
      let doc = if fields.get("files") is Some(Object(files)) &&
        fields.get("source") is Some(String(source)) {
        @valve.load_resolved(
          source,
          path => {
            match files.get(path) {
              Some(String(s)) => s
              _ => raise Failure("Missing virtual file: " + path)
            }
          },
          options=evaluated_options,
        )
      } else {
        @valve.parse(field(fields, "text"), options=evaluated_options)
      }
      Json::object({
        "tree": doc.to_json(),
        "text": Json::string(@valve.stringify(doc)),
      })
    }
    "resolve" => {
      guard fields.get("files") is Some(Object(files)) else {
        raise Failure("Expected virtual files")
      }
      let symbols = match fields.get("symbols") {
        Some(Array(values)) =>
          Some(
            values.map(value => {
              match value {
                String(s) => s
                _ => raise Failure("Symbols must be strings")
              }
            }),
          )
        _ => None
      }
      let doc = @valve.load_resolved(
        field(fields, "source"),
        path => {
          match files.get(path) {
            Some(String(s)) => s
            _ => raise Failure("Missing virtual file: " + path)
          }
        },
        options={ ..options, conditions: symbols, },
      )
      Json::object({
        "tree": doc.to_json(),
        "text": Json::string(@valve.stringify(doc)),
      })
    }
    "apply" => {
      guard fields.get("changes") is Some(changes) else {
        raise Failure("Expected changes")
      }
      let source = @valve.parse_preserving(field(fields, "text"), options~)
      let plan = @valve.changes_from_json(changes)
      let edited = if fields.get("sequential") == Some(Json::boolean(true)) {
        let mut result = source
        for change in plan {
          result = result.edit(change.path, change.operation)
        }
        result
      } else {
        source.apply(plan)
      }
      Json::object({
        "tree": edited.document().to_json(),
        "text": Json::string(edited.text()),
      })
    }
    "format" => {
      let source = @valve.parse_preserving(field(fields, "text"), options~)
      Json::object({ "text": Json::string(@valve.stringify(source.document())) })
    }
    "binary-decode" => {
      let bytes = @base64.decode(field(fields, "base64")[:])
      Json::object({
        "tree": @valve.binary_to_json(@valve.decode_binary(bytes)),
      })
    }
    "binary-encode" => {
      guard fields.get("tree") is Some(tree) else {
        raise Failure("Expected a typed tree")
      }
      let bytes = @valve.encode_binary(@valve.binary_from_json(tree))
      Json::object({
        "base64": Json::string(@base64.encode(bytes[:])),
        "size": Json::number(bytes.length().to_double()),
      })
    }
    "stream" => {
      let events : Array[Json] = []
      let parser = @valve.new_stream_parser(
        event => {
          let value = match event {
            @valve.Pair(k, v) =>
              Json::array([
                Json::string("pair"),
                Json::string(k),
                Json::string(v),
              ])
            @valve.BeginObject(k) =>
              Json::array([Json::string("begin"), Json::string(k)])
            @valve.EndObject => Json::array([Json::string("end")])
            @valve.Condition(k, c) =>
              Json::array([
                Json::string("condition"),
                Json::string(k),
                Json::string(c),
              ])
          }
          events.push(value)
          true
        },
        options~,
      )
      guard fields.get("chunks") is Some(Array(chunks)) else {
        raise Failure("Expected chunks")
      }
      for chunk in chunks {
        guard chunk is String(s) else {
          raise Failure("Expected string chunks")
        }
        parser.feed(s)
      }
      parser.finish()
      Json::object({ "events": Json::array(events) })
    }
    _ => raise Failure("Unknown action")
  }
}

///|
/// One JSON envelope keeps the browser and test harness on the same MoonBit core.
#export_name("dispatch")
pub fn dispatch(input : String) -> String {
  try {
    if input.char_length() > 33554432 {
      raise Failure("Request exceeds limit")
    }
    Json::object({
      "ok": Json::boolean(true),
      "result": execute(@json.parse(input[:])),
    }).stringify()
  } catch {
    @valve.ParseError(d) =>
      Json::object({
        "ok": Json::boolean(false),
        "error": Json::object({
          "code": Json::string(d.code),
          "message": Json::string(d.message),
          "offset": Json::number(d.offset.to_double()),
          "line": Json::number(d.line.to_double()),
          "column": Json::number(d.column.to_double()),
        }),
      }).stringify()
    error =>
      Json::object({
        "ok": Json::boolean(false),
        "error": Json::object({
          "code": Json::string("operation_failed"),
          "message": Json::string(error.to_string()),
        }),
      }).stringify()
  }
}
