///|
suberror CliError {
  InvalidArgument(String)
}

///|
/// The host supplies bounded UTF-8 file IO; KV1 and Steam semantics are MoonBit.
extern "js" fn host_read(path : String) -> FixedArray[String] =
  #| function(path) {
  #|   try {
  #|     const fs = require('node:fs');
  #|     const fd = path === '-' ? 0 : fs.openSync(path, 'r');
  #|     const chunks = [];
  #|     let total = 0;
  #|     try {
  #|       for (;;) {
  #|         const buffer = Buffer.alloc(65536);
  #|         const n = fs.readSync(fd, buffer, 0, buffer.length, null);
  #|         if (!n) break;
  #|         total += n;
  #|         if (total > 16 * 1024 * 1024) throw new Error('Input exceeds 16 MiB');
  #|         chunks.push(buffer.subarray(0, n));
  #|       }
  #|       return [new TextDecoder('utf-8', {fatal: true}).decode(Buffer.concat(chunks)), ''];
  #|     } finally { if (fd !== 0) fs.closeSync(fd); }
  #|   } catch (e) { return ['', e.message || 'Unable to read input']; }
  #| }

///|
extern "js" fn host_error(message : String, code : Int) -> Unit =
  #| function(message, code) { process.stderr.write(message + '\n'); process.exitCode = code; }

///|
extern "js" fn host_output(text : String) -> Unit =
  #| function(text) { process.stdout.write(text); }

///|
extern "js" fn host_manifest_paths(
  source : String,
  library : String,
) -> FixedArray[String] =
  #| function(source, library) {
  #|   try {
  #|     const fs = require('node:fs'), path = require('node:path');
  #|     const base = path.isAbsolute(library) ? library : path.resolve(path.dirname(source), library);
  #|     const dir = path.join(base, 'steamapps');
  #|     const files = fs.readdirSync(dir, {withFileTypes: true})
  #|       .filter(f => f.isFile() && /^appmanifest_[0-9]+\.acf$/.test(f.name))
  #|       .map(f => path.join(dir, f.name)).sort();
  #|     if (files.length > 100000) throw new Error('Too many manifests in library');
  #|     return ['', ...files];
  #|   } catch (e) { return [e.message || 'Unable to list library']; }
  #| }

///|
extern "js" fn host_exit_code(code : Int) -> Unit =
  #| function(code) { process.exitCode = code; }

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
  println(
    "Usage: moon run cmd/main --target js -- <command> <file|-> [keys...]",
  )
  println("  parse FILE           Export ordered, duplicate-preserving JSON")
  println("  from-json FILE       Import ordered JSON and emit KV1")
  println("  format FILE          Write canonical escaped KV1 to stdout")
  println(
    "  query FILE KEY...    Look up an exact path (each key is an argument)",
  )
  println("  app FILE             Read one Steam appmanifest_*.acf")
  println("  libraries FILE       Read libraryfolders.vdf")
  println("  inventory FILE       List installed manifests in each library")
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
fn inventory(source : String, doc : @valve.Document) -> Unit raise {
  if source == "-" {
    raise InvalidArgument("inventory requires a libraryfolders file path")
  }
  let games : Array[Json] = []
  let errors : Array[Json] = []
  for library in @valve.read_library_folders(doc) {
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
        games.push(
          Json::object({
            "library": Json::string(library.path),
            "manifest": Json::string(paths[i]),
            "app": app_json(app),
          }),
        )
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
  println(
    Json::object({ "games": Json::array(games), "errors": Json::array(errors) }).stringify(),
  )
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
  if command != "query" && args.length() != 4 {
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
    "inventory" => inventory(args[3], doc)
    _ => ()
  }
}

///|
fn main {
  run(@env.args()) catch {
    @valve.ParseError(d) =>
      host_error("\{d.code} at \{d.line}:\{d.column}: \{d.message}", 2)
    @valve.InvalidManifest(message) =>
      host_error("invalid_manifest: \{message}", 2)
    @valve.InvalidDocument(message) =>
      host_error("invalid_document: \{message}", 2)
    InvalidArgument(message) => host_error(message, 2)
    error => host_error(error.to_string(), 2)
  }
}
