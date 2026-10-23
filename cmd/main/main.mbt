///|
suberror CliError {
  InvalidArgument(String)
}

///|
fn read_text(path : String) -> String raise CliError {
  let result = host_read(path)
  if result[1] != "" {
    raise InvalidArgument(result[1])
  }
  result[0]
}

///|
fn help() -> Unit {
  println("MoonValve — Valve KeyValues 1 tools")
  println("Usage: moonvalve <command> <file|-> [keys/options...]")
  println("  parse FILE           Export ordered, duplicate-preserving JSON")
  println("  from-json FILE       Import ordered JSON and emit KV1")
  println("  format FILE          Write canonical escaped KV1 to stdout")
  println(
    "  query FILE KEY...    Look up an exact path (each key is an argument)",
  )
  println("  app FILE             Read one Steam appmanifest_*.acf")
  println("  libraries FILE       Read libraryfolders.vdf")
  println("  inventory FILE [--filter TEXT] [--sort id|name|size] [--csv]")
  println("  help                 Show this message")
}

///|
fn app_json(app : @valve.SteamApp) -> Json {
  let fields : Map[String, Json] = Map([])
  fields["app_id"] = Json::string(app.app_id)
  fields["name"] = Json::string(app.name)
  fields["install_dir"] = Json::string(app.install_dir)
  fields["size_on_disk"] = match app.size_on_disk {
    Some(n) => Json::string(n.to_string())
    None => Json::null()
  }
  fields["build_id"] = match app.build_id {
    Some(s) => Json::string(s)
    None => Json::null()
  }
  Json::object(fields)
}

///|
fn libraries_json(libraries : Array[@valve.SteamLibrary]) -> Json {
  Json::array(
    libraries.map(lib => {
      let fields : Map[String, Json] = Map([])
      fields["index"] = Json::string(lib.index)
      fields["path"] = Json::string(lib.path)
      fields["label"] = match lib.label {
        Some(s) => Json::string(s)
        None => Json::null()
      }
      fields["app_ids"] = Json::array(lib.app_ids.map(Json::string))
      Json::object(fields)
    }),
  )
}

///|
fn inventory(
  source : String,
  doc : @valve.Document,
  args : Array[String],
) -> Unit raise {
  if source == "-" {
    raise InvalidArgument("inventory requires a libraryfolders file path")
  }
  let mut filter = ""
  let mut sort = "id"
  let mut csv = false
  let mut option = 4
  while option < args.length() {
    match args[option] {
      "--csv" => csv = true
      "--filter" | "--sort" => {
        if option + 1 >= args.length() {
          raise InvalidArgument("Option needs a value")
        }
        if args[option] == "--filter" {
          filter = args[option + 1]
        } else {
          sort = args[option + 1]
        }
        option += 1
      }
      other => raise InvalidArgument("Unknown inventory option: " + other)
    }
    option += 1
  }
  @valve.select_inventory([], filter~, sort~) |> ignore
  let records : Array[@valve.InventoryRecord] = []
  let errors : Array[Json] = []
  let libraries = @valve.read_library_folders(doc)
  let scanned : Map[String, Bool] = Map([])
  for library in libraries {
    if scanned.contains(library.path) {
      continue
    }
    scanned[library.path] = true
    let paths = host_manifest_paths(source, library.path)
    if paths[0] != "" {
      errors.push(
        Json::object({
          "library": Json::string(library.path),
          "error": Json::string(paths[0]),
        }),
      )
      continue
    }
    for i in 1..<paths.length() {
      try {
        let app = @valve.read_app_manifest(@valve.parse(read_text(paths[i])))
        records.push({ library: library.path, manifest: paths[i], app, })
      } catch {
        error =>
          errors.push(
            Json::object({
              "manifest": Json::string(paths[i]),
              "error": Json::string(error.to_string()),
            }),
          )
      }
    }
  }
  for issue in @valve.check_inventory(libraries, records) {
    errors.push(
      Json::object({
        "code": Json::string(issue.code),
        "library": Json::string(issue.library),
        "manifest": match issue.manifest {
          Some(s) => Json::string(s)
          None => Json::null()
        },
        "error": Json::string(issue.message),
      }),
    )
  }
  let selected = @valve.select_inventory(records, filter~, sort~)
  let total = @valve.inventory_total(selected)
  if csv {
    host_output(@valve.inventory_csv(selected))
    for error in errors {
      host_error(error.stringify(), 1)
    }
  } else {
    let games = selected.map(record => {
      Json::object({
        "library": Json::string(record.library),
        "manifest": Json::string(record.manifest),
        "app": app_json(record.app),
      })
    })
    println(
      Json::object({
        "games": Json::array(games),
        "errors": Json::array(errors),
        "summary": Json::object({
          "count": Json::number(selected.length().to_double()),
          "scanned_count": Json::number(records.length().to_double()),
          "known_size_bytes": Json::string(total.known_size_bytes.to_string()),
          "unknown_size_count": Json::number(
            total.unknown_size_count.to_double(),
          ),
        }),
      }).stringify(),
    )
  }
  if !errors.is_empty() {
    host_exit_code(1)
  }
}

///|
fn run(args : Array[String]) -> Unit raise {
  if args.length() <= 2 || args[2] == "help" || args[2] == "--help" {
    help()
    return
  }
  let command = args[2]
  if command != "parse" &&
    command != "format" &&
    command != "query" &&
    command != "app" &&
    command != "libraries" &&
    command != "inventory" &&
    command != "from-json" {
    raise InvalidArgument("Unknown command: \{command}")
  }
  if args.length() < 4 {
    raise InvalidArgument("A file path or - for stdin is required")
  }
  if command != "query" && command != "inventory" && args.length() != 4 {
    raise InvalidArgument("Unexpected extra arguments")
  }
  if command == "query" && args.length() < 5 {
    raise InvalidArgument("query needs at least one key")
  }
  let input = read_text(args[3])
  if command == "from-json" {
    host_output(@valve.stringify(@valve.parse_json_document(input)))
    return
  }
  let doc = @valve.parse(input)
  match command {
    "parse" => println(doc.to_json().stringify())
    "format" => host_output(@valve.stringify(doc))
    "query" => {
      let keys : Array[String] = []
      for i in 4..<args.length() {
        keys.push(args[i])
      }
      match doc.lookup(keys) {
        Some(@valve.Text(text)) => println(Json::string(text).stringify())
        Some(@valve.Object(entries)) =>
          println(@valve.Document::{ entries, }.to_json().stringify())
        None => raise InvalidArgument("Path not found")
      }
    }
    "app" => println(app_json(@valve.read_app_manifest(doc)).stringify())
    "libraries" =>
      println(libraries_json(@valve.read_library_folders(doc)).stringify())
    "inventory" => inventory(args[3], doc, args)
    _ => ()
  }
}

///|
fn main {
  run(cli_args()) catch {
    @valve.ParseError(d) =>
      host_error("\{d.code} at \{d.line}:\{d.column}: \{d.message}", 2)
    @valve.InvalidManifest(message) =>
      host_error("invalid_manifest: \{message}", 2)
    @valve.InvalidDocument(message) =>
      host_error("invalid_document: \{message}", 2)
    InvalidArgument(message) => host_error(message, 2)
    error => host_error(error.to_string(), 2)
  }
  host_finish()
}
