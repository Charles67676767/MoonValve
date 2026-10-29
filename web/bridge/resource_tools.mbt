///|
fn resource_bytes(text : String) -> Bytes raise {
  if text.length() > 22369624 {
    raise Failure("Binary input exceeds 16 MiB")
  }
  let bytes = @base64.decode(text)
  if bytes.length() > 16777216 {
    raise Failure("Binary input exceeds 16 MiB")
  }
  bytes
}

///|
fn resource_files(json : Json) -> Map[String, Bytes] raise {
  guard json is Object(rows) && rows.length() <= 2048 else {
    raise Failure("Expected at most 2048 explicit files")
  }
  let files : Map[String, Bytes] = Map([])
  let mut total = 0
  for (path, value) in rows {
    guard value is String(base64) else {
      raise Failure("Expected base64 file contents")
    }
    let bytes = resource_bytes(base64)
    if bytes.length() > 67108864 - total {
      raise Failure("File bundle exceeds 64 MiB")
    }
    total += bytes.length()
    files[path] = bytes
  }
  files
}

///|
fn resource_base64(bytes : Bytes) -> Json {
  Json::object({
    "base64": Json::string(@base64.encode(bytes[:])),
    "size": Json::number(bytes.length().to_double()),
  })
}

///|
fn resource_field(fields : Map[String, Json], key : String) -> Json raise {
  guard fields.get(key) is Some(value) else {
    raise Failure("Expected field: " + key)
  }
  value
}

///|
fn resource_int(
  fields : Map[String, Json],
  key : String,
  fallback : Int,
  max : Int,
) -> Int raise {
  match fields.get(key) {
    None => fallback
    Some(Number(n, ..)) if n >= 0.0 &&
      n <= max.to_double() &&
      n == n.to_int().to_double() => n.to_int()
    _ => raise Failure("Invalid integer field: " + key)
  }
}

///|
fn resource_string(
  fields : Map[String, Json],
  key : String,
  fallback : String,
) -> String raise {
  if fields.get(key) is None {
    fallback
  } else {
    field(fields, key)
  }
}

///|
fn resource_graph(fields : Map[String, Json]) -> @valve.DependencyGraph raise {
  let files = resource_files(resource_field(fields, "files"))
  let base = match fields.get("base_files") {
    Some(value) => resource_files(value)
    None => Map([])
  }
  guard resource_field(fields, "roots") is Array(roots) else {
    raise Failure("Expected root path array")
  }
  let roots = roots.map(value => {
    guard value is String(s) else { raise Failure("Expected root path string") }
    s
  })
  let fs = @valve.mount_game_filesystem([
    @valve.LooseMount("mod", false, p => files.contains(p), p => files[p]),
    @valve.LooseMount("base", true, p => base.contains(p), p => base[p]),
  ])
  @valve.build_dependency_graph(roots, fs)
}

///|
fn execute_resource_tools(
  action : String,
  fields : Map[String, Json],
) -> Json? raise {
  let result = match action {
    "resource-inspect" => {
      let container = @valve.read_resource_container(
        resource_bytes(field(fields, "base64")),
      )
      let data = container.blocks.filter(b => b.kind == "DATA")
      let model = if data.length() == 1 &&
        data[0].bytes.length() >= 4 &&
        (
          (
            data[0].bytes[1] == b'3' &&
            data[0].bytes[2] == b'V' &&
            data[0].bytes[3] == b'K'
          ) ||
          data[0].bytes[:4].to_owned() == b"VKV\x03"
        ) {
        @valve.kv3_binary_to_json(container.data())
      } else {
        Json::null()
      }
      Json::object({
        "version": Json::number(container.version.to_double()),
        "declared_size": Json::number(container.declared_size.to_double()),
        "trailing_bytes": Json::number(container.trailing.length().to_double()),
        "blocks": Json::array(
          container.blocks.map(b => {
            Json::object({
              "kind": Json::string(b.kind),
              "offset": Json::number(b.offset.to_double()),
              "size": Json::number(b.bytes.length().to_double()),
            })
          }),
        ),
        "references": Json::array(
          container
          .external_references()
          .map(r => {
            Json::object({
              "id": Json::string(r.id.to_string()),
              "name": Json::string(r.name),
            })
          }),
        ),
        "model": model,
      })
    }
    "kv3-resource-encode" =>
      resource_base64(
        @valve.encode_kv3_resource(
          @valve.kv3_binary_from_json(resource_field(fields, "model")),
          resource_version=resource_int(fields, "resource_version", 1, 65535),
          version=resource_int(fields, "version", 5, 5),
          compression=resource_int(fields, "compression", 0, 2),
        ),
      )
    "kv3-binary-query" | "kv3-binary-edit" => {
      let document = @valve.kv3_binary_from_json(
        resource_field(fields, "model"),
      )
      let expression = field(fields, "expression")
      if action == "kv3-binary-query" {
        Json::array(
          document
          .select(expression)
          .map(row => {
            let packed = @valve.kv3_binary_to_json({
              ..document,
              root: row.value,
            })
            Json::object({
              "path": Json::array(row.path.map(Json::string)),
              "value": packed,
            })
          }),
        )
      } else {
        @valve.kv3_binary_to_json(
          document.edit_query(
            expression,
            @valve.kv3_query_edit_from_json(resource_field(fields, "operation")),
          ),
        )
      }
    }
    "vpk-index" =>
      @valve.read_vpk(resource_bytes(field(fields, "base64"))).to_json()
    "vpk-extract" => {
      let archive = @valve.read_vpk(resource_bytes(field(fields, "base64")))
      let ranges = match fields.get("ranges") {
        Some(Object(rows)) => rows
        None => Map([])
        _ => raise Failure("Expected VPK range map")
      }
      resource_base64(
        archive.read(field(fields, "path"), (id, offset, length) => {
          let key = id.to_string() +
            ":" +
            offset.to_string() +
            ":" +
            length.to_string()
          guard ranges.get(key) is Some(String(data)) else {
            raise Failure("Missing VPK byte range: " + key)
          }
          resource_bytes(data)
        }),
      )
    }
    "vpk-create" | "files-zip" => {
      let files = resource_files(resource_field(fields, "files"))
      resource_base64(
        if action == "vpk-create" {
          @valve.create_vpk(
            files,
            preload_bytes=resource_int(fields, "preload", 0, 65535),
          )
        } else {
          @valve.export_files_zip(files)
        },
      )
    }
    "dependencies" | "dependencies-export" => {
      let graph = resource_graph(fields)
      if action == "dependencies" {
        Json::object({
          "graph": graph.to_json(),
          "dependents": Json::array(
            if fields.get("target") is Some(String(target)) {
              graph.dependents(target).map(Json::string)
            } else {
              []
            },
          ),
        })
      } else {
        let include_base = fields.get("include_base") ==
          Some(Json::boolean(true))
        let strict = fields.get("strict") != Some(Json::boolean(false))
        resource_base64(
          if resource_string(fields, "format", "zip") == "vpk" {
            graph.export_vpk(include_base~, strict~)
          } else {
            graph.export_zip(include_base~, strict~)
          },
        )
      }
    }
    "vmt-parse" | "vmt-expand" | "vmt-parameter" => {
      let source = resource_string(fields, "source", "material.vmt")
      let material = if action == "vmt-expand" {
        guard resource_field(fields, "files") is Object(files) else {
          raise Failure("Expected VMT source files")
        }
        @valve.load_vmt(source, p => {
          guard files.get(p) is Some(String(text)) else {
            raise Failure("VMT include was not supplied: " + p)
          }
          text
        })
      } else {
        @valve.parse_vmt(field(fields, "text"), source~)
      }
      let material = if action == "vmt-parameter" {
        material.with_parameter(field(fields, "key"), field(fields, "value"))
      } else {
        material
      }
      Json::object({
        "model": material.to_json(),
        "text": Json::string(material.stringify()),
      })
    }
    "localization-read" =>
      @valve.read_localization(resource_bytes(field(fields, "base64"))).to_json()
    "localization-write" =>
      resource_base64(
        @valve.localization_from_json(resource_field(fields, "model")).write(
          encoding=resource_string(fields, "encoding", "utf16le"),
        ),
      )
    "localization-po" => {
      let source = @valve.read_localization(
        resource_bytes(field(fields, "base64")),
      )
      let po = if fields.get("translation") is Some(String(raw)) {
        source.to_po(translated=@valve.read_localization(resource_bytes(raw)))
      } else {
        source.to_po()
      }
      Json::object({ "text": Json::string(po.stringify()) })
    }
    "localization-import-po" => {
      let source = @valve.read_localization(
        resource_bytes(field(fields, "base64")),
      )
      let imported = source.import_po(
        @valve.parse_po(field(fields, "po")),
        field(fields, "language"),
        syntax=resource_string(fields, "syntax", "valve"),
        allow_fuzzy=fields.get("allow_fuzzy") == Some(Json::boolean(true)),
      )
      Json::object({
        "model": imported.document.to_json(),
        "base64": Json::string(
          @base64.encode(
            imported.document.write(
              encoding=resource_string(fields, "encoding", source.encoding),
            )[:],
          ),
        ),
        "issues": @valve.localization_issues_to_json(imported.issues),
      })
    }
    "po-update" =>
      Json::object({
        "text": Json::string(
          @valve.update_po(
            @valve.parse_po(field(fields, "template")),
            @valve.parse_po(field(fields, "previous")),
          ).stringify(),
        ),
      })
    "po-format" =>
      Json::object({
        "text": Json::string(@valve.parse_po(field(fields, "text")).stringify()),
      })
    "dmx-read" => {
      let doc = @valve.read_dmx(resource_bytes(field(fields, "base64")))
      Json::object({
        "model": @valve.dmx_to_json(doc),
        "text": Json::string(@valve.stringify_dmx(doc)),
        "external_references": Json::array(
          doc.external_references().map(Json::string),
        ),
      })
    }
    "dmx-write" => {
      let doc = @valve.dmx_from_json(resource_field(fields, "model"))
      resource_base64(
        if resource_string(fields, "encoding", "binary") == "text" {
          @utf8.encode(@valve.stringify_dmx(doc)[:])
        } else {
          @valve.encode_dmx_binary(
            doc,
            version=resource_int(fields, "version", 5, 5),
          )
        },
      )
    }
    _ => return None
  }
  Some(result)
}
