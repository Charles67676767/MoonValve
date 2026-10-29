///|
fn asset_json_field(fields : Map[String, Json], key : String) -> String raise {
  guard fields.get(key) is Some(String(s)) else {
    raise InvalidArgument("Expected string field: " + key)
  }
  s
}

///|
fn asset_output(bytes : Bytes, target : String?) -> Unit raise {
  if target is Some(path) {
    host_write_new(path, bytes)
  } else {
    host_output_bytes(bytes)
    host_output_check()
  }
}

///|
fn asset_codec(raw : String) -> Int raise {
  match raw {
    "raw" | "0" => 0
    "lz4" | "1" => 1
    "zstd" | "2" => 2
    _ => raise InvalidArgument("Expected raw, lz4 or zstd")
  }
}

///|
fn asset_vpk(file : String) -> @valve.VPKArchive raise {
  let header = host_read_range(file, 0, 12)
  let version = header[4].to_int()
  if header[:4].to_owned() != b"\x34\x12\xaa\x55" ||
    header[5:8].to_owned() != b"\x00\x00\x00" ||
    (version != 1 && version != 2) {
    raise InvalidArgument("Unsupported VPK header")
  }
  let mut size = 0UL
  for i in 0..<4 {
    size = size | (header[8 + i].to_uint64() << (8 * i))
  }
  if size > 16777216UL {
    raise InvalidArgument("VPK directory tree exceeds 16 MiB")
  }
  @valve.read_vpk(
    host_read_range(
      file,
      0,
      size.to_int() + (if version == 1 { 12 } else { 28 }),
    ),
    options={ ..@valve.BinaryOptions::default(), max_bytes: 67108864, },
  )
}

///|
fn asset_vpk_range(
  file : String,
  archive : Int,
  offset : Int,
  length : Int,
) -> Bytes raise {
  let source = if archive == 32767 {
    file
  } else {
    if !file.to_lower().has_suffix("_dir.vpk") {
      raise InvalidArgument(
        "Numbered VPK archives require a *_dir.vpk directory filename",
      )
    }
    let index = archive.to_string()
    file[:file.length() - 8].to_owned() +
    "_" +
    String::make((3 - index.length()).max(0), '0') +
    index +
    ".vpk"
  }
  host_read_range(source, offset, length)
}

///|
fn asset_bundle(json : Json) -> Map[String, Bytes] raise {
  guard json is Object(rows) && rows.length() <= 2048 else {
    raise InvalidArgument("Expected a path-to-base64 file object")
  }
  let files : Map[String, Bytes] = Map([])
  let mut total = 0
  for (name, value) in rows {
    guard value is String(raw) && raw.length() <= 89478488 else {
      raise InvalidArgument("Expected bounded base64 file contents")
    }
    let bytes = @base64.decode(raw)
    if bytes.length() > 67108864 - total {
      raise InvalidArgument("File bundle exceeds 64 MiB")
    }
    total += bytes.length()
    files[name] = bytes
  }
  files
}

///|
fn asset_dependency_graph(file : String) -> @valve.DependencyGraph raise {
  guard @json.parse(input_text(file)[:]) is Object(fields) &&
    fields.get("roots") is Some(Array(roots)) &&
    fields.get("mounts") is Some(Array(mounts)) &&
    mounts.length() <= 128 else {
    raise InvalidArgument(
      "Expected roots and explicit mounts in dependency manifest",
    )
  }
  let mounts = mounts.map(mount => {
    guard mount is Object(row) else {
      raise InvalidArgument("Expected mount object")
    }
    let id = asset_json_field(row, "id")
    let base = row.get("base_game") == Some(Json::boolean(true))
    if row.get("root") is Some(String(root)) {
      if row.contains("vpk") {
        raise InvalidArgument("Mount must specify either root or vpk")
      }
      @valve.LooseMount(
        id,
        base,
        p => {
          try {
            host_confined(root, p) |> ignore
            true
          } catch {
            _ => false
          }
        },
        p => host_read_bytes(host_confined(root, p)),
      )
    } else {
      let path = asset_json_field(row, "vpk")
      @valve.VPKMount(id, base, asset_vpk(path), (archive, offset, length) => {
        asset_vpk_range(path, archive, offset, length)
      })
    }
  })
  @valve.build_dependency_graph(
    roots.map(value => {
      guard value is String(s) else {
        raise InvalidArgument("Expected dependency root path")
      }
      s
    }),
    @valve.mount_game_filesystem(mounts),
  )
}

///|
fn asset_resource_json(container : @valve.ResourceContainer) -> Json raise {
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
  })
}

///|
fn resource_help() -> Unit {
  for
    line in [
      "  kv3-binary-decode / kv3-binary-to-text FILE", "  kv3-binary-encode MODEL.json [4|5 [raw|lz4|zstd]]",
      "  kv3-text-to-binary FILE [4|5 [raw|lz4|zstd]]", "  kv3-binary-select FILE EXPR",
      "  kv3-binary-edit FILE EXPR OP.json [NEW-OUTPUT]", "  resource-inspect / resource-data FILE",
      "  kv3-resource-encode MODEL.json [4|5 [raw|lz4|zstd]]", "  vpk-index / vpk-check FILE",
      "  vpk-extract FILE PATH [NEW-OUTPUT]", "  vpk-extract-all FILE NEW-DIRECTORY",
      "  vpk-create BUNDLE.json [NEW-OUTPUT]", "  dependencies MANIFEST.json [REVERSE-TARGET]",
      "  dependencies-export MANIFEST.json NEW-OUTPUT zip|vpk|directory", "  vmt-parse FILE | vmt-expand RELATIVE-FILE ROOT-DIRECTORY",
      "  vmt-set FILE PARAMETER VALUE", "  localization-read FILE | localization-write MODEL.json [ENCODING]",
      "  localization-pot SOURCE | localization-po SOURCE TRANSLATION", "  localization-import SOURCE PO LANGUAGE [SYNTAX [ENCODING]]",
      "  po-format FILE | po-update TEMPLATE PREVIOUS", "  dmx-decode / dmx-to-text FILE | dmx-from-json MODEL.json",
      "  dmx-binary FILE [4|5]    Read either DMX encoding and write binary",
    ] {
    println(line)
  }
}

///|
fn run_resource_commands(command : String, args : Array[String]) -> Bool raise {
  let commands = [
    "kv3-binary-decode", "kv3-binary-to-text", "kv3-binary-encode", "kv3-text-to-binary",
    "kv3-binary-select", "kv3-binary-edit", "resource-inspect", "resource-data",
    "kv3-resource-encode", "vpk-index", "vpk-check", "vpk-extract", "vpk-extract-all",
    "vpk-create", "dependencies", "dependencies-export", "vmt-parse", "vmt-expand",
    "vmt-set", "localization-read", "localization-write", "localization-pot", "localization-po",
    "localization-import", "po-format", "po-update", "dmx-decode", "dmx-to-text",
    "dmx-from-json", "dmx-binary",
  ]
  if !commands.contains(command) {
    return false
  }
  if args.length() < 4 {
    raise InvalidArgument("A file path is required")
  }
  let file = args[3]
  let words = args[4:].to_owned()
  if words.any(s => s.has_prefix("--")) {
    raise InvalidArgument("Unexpected option for resource command")
  }
  match command {
    "kv3-binary-decode" | "kv3-binary-to-text" => {
      if !words.is_empty() {
        raise InvalidArgument("Unexpected arguments")
      }
      let document = @valve.decode_kv3_binary(host_read_bytes(file))
      host_output(
        if command == "kv3-binary-decode" {
          @valve.kv3_binary_to_json(document).stringify() + "\n"
        } else {
          @valve.stringify_kv3(document.document())
        },
      )
    }
    "kv3-binary-encode" | "kv3-text-to-binary" | "kv3-resource-encode" => {
      if words.length() > 2 {
        raise InvalidArgument("Expected optional version and codec")
      }
      let version = if words.is_empty() {
        5
      } else {
        @strconv.parse_int(words[0][:])
      }
      let compression = if words.length() < 2 {
        0
      } else {
        asset_codec(words[1])
      }
      let document = if command == "kv3-text-to-binary" {
        @valve.kv3_binary_from_document(@valve.parse_kv3(input_text(file)))
      } else {
        @valve.kv3_binary_from_json(@json.parse(input_text(file)[:]))
      }
      asset_output(
        if command == "kv3-resource-encode" {
          @valve.encode_kv3_resource(document, version~, compression~)
        } else {
          @valve.encode_kv3_binary(document, version~, compression~)
        },
        None,
      )
    }
    "kv3-binary-select" | "kv3-binary-edit" => {
      if words.length() < (if command == "kv3-binary-select" { 1 } else { 2 }) ||
        words.length() > (if command == "kv3-binary-select" { 1 } else { 3 }) {
        raise InvalidArgument(
          "Expected query expression and optional edit plan/output",
        )
      }
      let document = @valve.decode_kv3_binary(host_read_bytes(file))
      if command == "kv3-binary-select" {
        println(
          Json::array(
            document
            .select(words[0])
            .map(row => {
              Json::object({
                "path": Json::array(row.path.map(Json::string)),
                "value": @valve.kv3_binary_to_json({
                  ..document,
                  root: row.value,
                }),
              })
            }),
          ).stringify(),
        )
      } else {
        let edited = document.edit_query(
          words[0],
          @valve.kv3_query_edit_from_json(@json.parse(input_text(words[1])[:])),
        )
        asset_output(
          @valve.encode_kv3_binary(
            edited,
            version=if document.version == 4 { 4 } else { 5 },
            compression=if document.compression <= 2 {
              document.compression
            } else {
              1
            },
          ),
          words.get(2),
        )
      }
    }
    "resource-inspect" | "resource-data" => {
      if !words.is_empty() {
        raise InvalidArgument("Unexpected arguments")
      }
      let container = @valve.read_resource_container(host_read_bytes(file))
      println(
        (if command == "resource-data" {
          @valve.kv3_binary_to_json(container.data())
        } else {
          asset_resource_json(container)
        }).stringify(),
      )
    }
    "vpk-index" | "vpk-check" | "vpk-extract" | "vpk-extract-all" => {
      let archive = asset_vpk(file)
      if command == "vpk-index" || command == "vpk-check" {
        if !words.is_empty() {
          raise InvalidArgument("Unexpected arguments")
        }
        if command == "vpk-check" {
          for entry in archive.entries() {
            archive.read(entry.path, (id, offset, length) => {
              asset_vpk_range(file, id, offset, length)
            })
            |> ignore
          }
          println(
            Json::object({
              "checked": Json::number(archive.entries().length().to_double()),
              "verification": Json::string("file-crc32"),
              "v2_footer_verified": Json::boolean(false),
            }).stringify(),
          )
        } else {
          println(archive.to_json().stringify())
        }
      } else if command == "vpk-extract" {
        if words.is_empty() || words.length() > 2 {
          raise InvalidArgument(
            "Expected VPK entry path and optional new output file",
          )
        }
        asset_output(
          archive.read(words[0], (id, offset, length) => {
            asset_vpk_range(file, id, offset, length)
          }),
          words.get(1),
        )
      } else {
        if words.length() != 1 {
          raise InvalidArgument("Expected a new output directory")
        }
        let files : Map[String, Bytes] = Map([])
        let mut total = 0
        for entry in archive.entries() {
          if entry.length + entry.preload.length() > 67108864 - total {
            raise InvalidArgument(
              "VPK extraction exceeds 64 MiB aggregate budget",
            )
          }
          let bytes = archive.read(entry.path, (id, offset, length) => {
            asset_vpk_range(file, id, offset, length)
          })
          total += bytes.length()
          files[entry.path] = bytes
        }
        host_export_binary_directory(words[0], files)
      }
    }
    "vpk-create" => {
      if words.length() > 1 {
        raise InvalidArgument("Expected optional new output file")
      }
      asset_output(
        @valve.create_vpk(asset_bundle(@json.parse(input_text(file)[:])), options={
          ..@valve.BinaryOptions::default(),
          max_bytes: 67108864,
        }),
        words.get(0),
      )
    }
    "dependencies" | "dependencies-export" =>
      if command == "dependencies" {
        if words.length() > 1 {
          raise InvalidArgument("Expected optional reverse reference target")
        }
        let graph = asset_dependency_graph(file)
        if words.get(0) is Some(target) {
          println(
            Json::array(graph.dependents(target).map(Json::string)).stringify(),
          )
        } else {
          println(graph.to_json().stringify())
        }
      } else {
        if words.length() != 2 {
          raise InvalidArgument(
            "Expected new output path and zip, vpk or directory",
          )
        }
        let graph = asset_dependency_graph(file)
        match words[1] {
          "zip" => host_write_new(words[0], graph.export_zip())
          "vpk" =>
            host_write_new(
              words[0],
              graph.export_vpk(options={
                ..@valve.BinaryOptions::default(),
                max_bytes: 67108864,
              }),
            )
          "directory" =>
            host_export_binary_directory(words[0], graph.export_files())
          _ => raise InvalidArgument("Expected zip, vpk or directory")
        }
      }
    "vmt-parse" | "vmt-expand" | "vmt-set" => {
      if words.length() !=
        (if command == "vmt-parse" {
          0
        } else if command == "vmt-expand" {
          1
        } else {
          2
        }) {
        raise InvalidArgument("Unexpected VMT arguments")
      }
      let material = if command == "vmt-expand" {
        @valve.load_vmt(file, p => input_text(host_confined(words[0], p)))
      } else {
        @valve.parse_vmt(input_text(file), source=file)
      }
      if command == "vmt-set" {
        host_output(material.with_parameter(words[0], words[1]).stringify())
      } else if command == "vmt-expand" {
        host_output(material.stringify())
      } else {
        println(material.to_json().stringify())
      }
    }
    "localization-read"
    | "localization-write"
    | "localization-pot"
    | "localization-po"
    | "localization-import" =>
      if command == "localization-write" {
        if words.length() > 1 {
          raise InvalidArgument("Expected optional encoding")
        }
        let document = @valve.localization_from_json(
          @json.parse(input_text(file)[:]),
        )
        asset_output(
          document.write(encoding=words.get(0).unwrap_or(document.encoding)),
          None,
        )
      } else {
        let source = @valve.read_localization(host_read_bytes(file))
        if command == "localization-read" || command == "localization-pot" {
          if !words.is_empty() {
            raise InvalidArgument("Unexpected localization arguments")
          }
          host_output(
            if command == "localization-read" {
              source.to_json().stringify() + "\n"
            } else {
              source.to_po().stringify()
            },
          )
        } else if command == "localization-po" {
          if words.length() != 1 {
            raise InvalidArgument("Expected translation file")
          }
          host_output(
            source
            .to_po(
              translated=@valve.read_localization(host_read_bytes(words[0])),
            )
            .stringify(),
          )
        } else {
          if words.length() < 2 || words.length() > 4 {
            raise InvalidArgument(
              "Expected PO file, language and optional syntax/encoding",
            )
          }
          let imported = source.import_po(
            @valve.parse_po(input_text(words[0])),
            words[1],
            syntax=words.get(2).unwrap_or("valve"),
          )
          if !imported.issues.is_empty() {
            raise InvalidArgument(
              @valve.localization_issues_to_json(imported.issues).stringify(),
            )
          }
          asset_output(
            imported.document.write(
              encoding=words.get(3).unwrap_or(source.encoding),
            ),
            None,
          )
        }
      }
    "po-format" | "po-update" => {
      if words.length() != (if command == "po-update" { 1 } else { 0 }) {
        raise InvalidArgument("Unexpected PO arguments")
      }
      let catalog = @valve.parse_po(input_text(file))
      host_output(
        (if command == "po-update" {
          @valve.update_po(catalog, @valve.parse_po(input_text(words[0])))
        } else {
          catalog
        }).stringify(),
      )
    }
    "dmx-decode" | "dmx-to-text" | "dmx-from-json" | "dmx-binary" => {
      if words.length() > (if command == "dmx-binary" { 1 } else { 0 }) {
        raise InvalidArgument("Unexpected DMX arguments")
      }
      let doc = if command == "dmx-from-json" {
        @valve.dmx_from_json(@json.parse(input_text(file)[:]))
      } else {
        @valve.read_dmx(host_read_bytes(file))
      }
      if command == "dmx-decode" {
        println(@valve.dmx_to_json(doc).stringify())
      } else if command == "dmx-binary" {
        asset_output(
          @valve.encode_dmx_binary(
            doc,
            version=if words.is_empty() {
              5
            } else {
              @strconv.parse_int(words[0][:])
            },
          ),
          None,
        )
      } else {
        host_output(@valve.stringify_dmx(doc))
      }
    }
    _ => ()
  }
  true
}
