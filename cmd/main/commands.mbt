///|
let json_errors : Ref[Bool] = { val: false, }

///|
fn report_error(
  code : String,
  message : String,
  diagnostic : @valve.Diagnostic?,
) -> Unit {
  if json_errors.val {
    let fields : Map[String, Json] = {
      "code": Json::string(code),
      "message": Json::string(message),
    }
    if diagnostic is Some(d) {
      fields["offset"] = Json::number(d.offset.to_double())
      fields["line"] = Json::number(d.line.to_double())
      fields["column"] = Json::number(d.column.to_double())
    }
    host_error(Json::object(fields).stringify(), 2)
  } else {
    host_error(message, 2)
  }
}

///|
fn validate_reference_path(
  root : String,
  relative : String,
) -> Unit raise CliError {
  if root.contains("\u0000") ||
    relative.contains("\u0000") ||
    relative.has_prefix("/") ||
    relative.has_prefix("\\") ||
    relative.contains(":") ||
    @utf8.encode(root[:]).length() > 32767 ||
    @utf8.encode(relative[:]).length() > 32767 {
    raise InvalidArgument("References must be relative to an explicit root")
  }
}

///|
priv struct CommandOptions {
  words : Array[String]
  symbols : Array[String]?
  literal : Bool
  resolve : Bool
  root : String?
  inplace : Bool
  preview : Bool
  headerless : Bool
}

///|
fn command_options(args : Array[String]) -> CommandOptions raise CliError {
  let words : Array[String] = []
  let mut symbols : Array[String]? = None
  let mut literal = false
  let mut resolve = false
  let mut root = None
  let mut inplace = false
  let mut preview = false
  let mut headerless = false
  let mut i = 4
  let mut positional = false
  while i < args.length() {
    let arg = args[i]
    if positional {
      words.push(arg)
      i += 1
      continue
    }
    match arg {
      "--" => positional = true
      "--literal" => literal = true
      "--resolve" => resolve = true
      "--in-place" => inplace = true
      "--dry-run" => preview = true
      "--headerless" => headerless = true
      "--condition" | "--root" => {
        if i + 1 >= args.length() {
          raise InvalidArgument("Option requires a value: " + arg)
        }
        i += 1
        if arg == "--root" {
          root = Some(args[i])
        } else {
          match symbols {
            Some(values) => values.push(args[i])
            None => symbols = Some([args[i]])
          }
        }
      }
      other => {
        if other.has_prefix("--") {
          raise InvalidArgument("Unknown option: " + other)
        }
        words.push(other)
      }
    }
    i += 1
  }
  if inplace && preview {
    raise InvalidArgument("Choose either --in-place or --dry-run")
  }
  { words, symbols, literal, resolve, root, inplace, preview, headerless, }
}

///|
fn input_text(path : String) -> String raise {
  @utf8.decode(host_read_bytes(path)[:], ignore_bom=false)
}

///|
fn selected_document(
  file : String,
  opts : CommandOptions,
) -> @valve.Document raise {
  let options = {
    ..@valve.ParseOptions::default(),
    escape_sequences: !opts.literal,
    conditions: opts.symbols,
  }
  if opts.resolve {
    guard opts.root is Some(root) && file != "-" else {
      raise InvalidArgument(
        "--resolve requires --root DIR and a relative input filename",
      )
    }
    @valve.load_resolved(
      file,
      path => input_text(host_confined(root, path)),
      options~,
    )
  } else {
    if opts.root is Some(_) {
      raise InvalidArgument("--root is used with --resolve")
    }
    @valve.parse(input_text(file), options~)
  }
}

///|
fn preview_text(before : String, after : String) -> Json {
  let changed = before != after
  let diff = StringBuilder()
  if changed {
    let a = before.split("\n").collect()
    let b = after.split("\n").collect()
    diff.write_string(
      "--- before\n+++ after\n@@ -1,\{a.length()} +1,\{b.length()} @@\n",
    )
    for line in a {
      diff.write_string("-" + line.to_owned() + "\n")
    }
    for line in b {
      diff.write_string("+" + line.to_owned() + "\n")
    }
  }
  Json::object({
    "changed": Json::boolean(changed),
    "before": Json::string(before),
    "after": Json::string(after),
    "diff": Json::string(diff.to_string()),
  })
}

///|
fn emit_changed(
  file : String,
  before : Bytes,
  after : Bytes,
  opts : CommandOptions,
  text : Bool,
) -> Unit raise {
  if opts.inplace {
    if before != after {
      host_save(file, before, after)
    }
    println(
      Json::object({
        "written": Json::boolean(before != after),
        "backup": if before == after {
          Json::null()
        } else {
          Json::string(file + ".bak")
        },
      }).stringify(),
    )
  } else if opts.preview {
    if text {
      println(
        preview_text(@utf8.decode(before[:]), @utf8.decode(after[:])).stringify(),
      )
    } else {
      println(
        Json::object({
          "changed": Json::boolean(before != after),
          "before": @valve.binary_to_json(@valve.decode_binary(before)),
          "after": @valve.binary_to_json(@valve.decode_binary(after)),
        }).stringify(),
      )
    }
  } else {
    host_output_bytes(after)
  }
}

///|
fn reject_write_options(opts : CommandOptions) -> Unit raise CliError {
  if opts.inplace || opts.preview {
    raise InvalidArgument(
      "Write options are only supported by edit and shortcut commands",
    )
  }
}

///|
fn run(args : Array[String]) -> Unit raise {
  let args = if args.length() > 2 && args[2] == "--json-errors" {
    json_errors.val = true
    [args[0], args[1], ..args[3:]]
  } else {
    args
  }
  if args.length() > 2 && (args[2] == "version" || args[2] == "--version") {
    if args.length() != 3 {
      raise InvalidArgument("version accepts no arguments")
    }
    println(
      Json::object({
        "name": Json::string("MoonValve"),
        "version": Json::string(@valve.version()),
        "minimum_moonc": Json::string("0.10.14"),
      }).stringify(),
    )
    return
  }
  if args.length() <= 2 || args[2] == "help" || args[2] == "--help" {
    help()
    println("  version                 Show version information")
    println(
      "  select FILE EXPR        Query paths, duplicates and value filters",
    )
    println("  query-edit FILE EXPR OP.json [--dry-run|--in-place]")
    println("  edit-snapshot FILE PLAN.json [--dry-run|--in-place]")
    println("  transfer FILE PLAN.json [--dry-run|--in-place]")
    println("  kv3-parse / kv3-format FILE [--headerless]")
    println("  kv3-from-json FILE       Write typed KV3 JSON as text")
    println("  workspace-edit SNAPSHOT PLAN.json [--dry-run|--in-place]")
    println("  lsp                     Start UTF-8 framed LSP on stdio")
    println("  stream-json FILE        Emit raw events as JSON Lines")
    println("  stream-query FILE KEY... Stream matching raw scalar values")
    println("  stream-csv FILE         Emit raw scalar paths and values as CSV")
    println("  stream-format FILE      Stream canonical unconditional KV1")
    println("  query-all FILE KEY...    Follow all duplicate matches")
    println("  resolve FILE --root DIR  Expand references inside DIR")
    println(
      "  project FILE --root DIR Emit resolved tree, origins and reference graph",
    )
    println("  edit FILE PLAN.json [--dry-run|--in-place]")
    println("  binary-decode FILE       Emit typed ordered JSON")
    println("  binary-encode FILE       Import typed JSON and write bytes")
    println("  cache FILE [ID]          Index Steam cache or read one ID")
    println("  shortcuts FILE          List non-Steam shortcuts")
    println("  shortcut-add FILE DEFINITION.json [--dry-run|--in-place]")
    println("  shortcut-set FILE INDEX DEFINITION.json [--dry-run|--in-place]")
    println("  shortcut-remove FILE INDEX [--dry-run|--in-place]")
    println(
      "Text commands accept --condition NAME (repeatable), --literal, --resolve --root DIR.",
    )
    println(
      "Use --json-errors before the command for machine-readable errors. Saving creates FILE.bak.",
    )
    return
  }
  let command = args[2]
  if command == "lsp" {
    if args.length() != 3 {
      raise InvalidArgument("lsp takes no arguments")
    }
    run_lsp()
    return
  }
  if ["stream-json", "stream-query", "stream-csv", "stream-format"].contains(
      command,
    ) {
    run_stream(command, args)
    return
  }
  let expanded = [
    "select", "query-edit", "edit-snapshot", "transfer", "kv3-parse", "kv3-format",
    "kv3-from-json", "workspace-edit", "parse", "format", "query", "query-all", "resolve",
    "project", "edit", "binary-decode", "binary-encode", "cache", "shortcuts", "shortcut-add",
    "shortcut-set", "shortcut-remove",
  ]
  if !expanded.contains(command) {
    run_basic(args)
    return
  }
  if args.length() < 4 {
    raise InvalidArgument("A file path or - is required")
  }
  let file = args[3]
  let opts = command_options(args)
  if opts.headerless && !["kv3-parse", "kv3-format"].contains(command) {
    raise InvalidArgument("--headerless is only used when reading KV3")
  }
  if run_advanced(command, file, opts) {
    return
  }
  if command == "project" {
    reject_write_options(opts)
    guard opts.root is Some(root) && file != "-" && opts.words.is_empty() else {
      raise InvalidArgument(
        "project requires --root DIR and a relative input filename",
      )
    }
    let project = @valve.load_project(
      file,
      path => input_text(host_confined(root, path)),
      options={
        ..@valve.ParseOptions::default(),
        escape_sequences: !opts.literal,
        conditions: opts.symbols,
      },
    )
    host_output(project.to_json().stringify() + "\n")
    return
  }
  if command == "edit" {
    if opts.words.length() != 1 ||
      opts.resolve ||
      opts.symbols is Some(_) ||
      opts.root is Some(_) {
      raise InvalidArgument(
        "edit requires one plan and retains raw conditions and references",
      )
    }
    let before = host_read_bytes(file)
    let source = @valve.parse_preserving(@utf8.decode(before[:]), options={
      ..@valve.ParseOptions::default(),
      escape_sequences: !opts.literal,
    })
    let changes = @valve.changes_from_json(
      @json.parse(input_text(opts.words[0])[:]),
    )
    let after = source.apply(changes).text()
    emit_changed(file, before, @utf8.encode(after[:]), opts, true)
    return
  }
  if command.has_prefix("shortcut-") {
    run_shortcut_change(command, file, opts)
    return
  }
  reject_write_options(opts)
  if command == "binary-decode" ||
    command == "binary-encode" ||
    command == "cache" ||
    command == "shortcuts" {
    if opts.literal ||
      opts.resolve ||
      opts.root is Some(_) ||
      opts.symbols is Some(_) {
      raise InvalidArgument(
        "Text parsing options do not apply to binary commands",
      )
    }
    match command {
      "binary-decode" => {
        if !opts.words.is_empty() {
          raise InvalidArgument("Unexpected arguments")
        }
        println(
          @valve.binary_to_json(@valve.decode_binary(host_read_bytes(file))).stringify(),
        )
      }
      "binary-encode" => {
        if !opts.words.is_empty() {
          raise InvalidArgument("Unexpected arguments")
        }
        host_output_bytes(
          @valve.encode_binary(
            @valve.binary_from_json(@json.parse(input_text(file)[:])),
          ),
        )
      }
      "shortcuts" => {
        if !opts.words.is_empty() {
          raise InvalidArgument("Unexpected arguments")
        }
        println(
          shortcuts_json(
            @valve.read_shortcut_file(
              @valve.decode_binary(host_read_bytes(file)),
            ),
          ).stringify(),
        )
      }
      "cache" => {
        if opts.words.length() > 1 {
          raise InvalidArgument("cache accepts at most one identifier")
        }
        let cache = @valve.open_steam_cache(
          host_read_bytes(file, limit=536870912),
        )
        if opts.words.is_empty() {
          println(
            Json::object({
              "format": Json::string(
                if cache.format() == @valve.AppInfo {
                  "appinfo"
                } else {
                  "packageinfo"
                },
              ),
              "version": Json::number(cache.version().to_double()),
              "universe": Json::string(cache.universe().to_string()),
              "records": Json::array(
                cache
                .records()
                .map(row => {
                  Json::object({
                    "id": Json::string(row.id.to_string()),
                    "change_number": Json::string(row.change_number.to_string()),
                    "offset": Json::number(row.offset.to_double()),
                    "length": Json::number(row.length.to_double()),
                  })
                }),
              ),
            }).stringify(),
          )
        } else {
          let id = @strconv.parse_uint(opts.words[0][:])
          guard cache.read(id) is Some(data) else {
            raise InvalidArgument("Identifier is absent from cache")
          }
          println(@valve.binary_to_json(data).stringify())
        }
      }
      _ => ()
    }
    return
  }
  let opts = if command == "resolve" {
    { ..opts, resolve: true, }
  } else {
    opts
  }
  let doc = selected_document(file, opts)
  match command {
    "parse" => {
      if !opts.words.is_empty() {
        raise InvalidArgument("Unexpected arguments")
      }
      println(doc.to_json().stringify())
    }
    "format" | "resolve" => {
      if !opts.words.is_empty() {
        raise InvalidArgument("Unexpected arguments")
      }
      host_output(@valve.stringify(doc))
    }
    "query" => {
      if opts.words.is_empty() {
        raise InvalidArgument("query needs at least one key")
      }
      guard doc.lookup(opts.words) is Some(value) else {
        raise InvalidArgument("Path not found")
      }
      println(text_value_json(value).stringify())
    }
    "query-all" => {
      if opts.words.is_empty() {
        raise InvalidArgument("query-all needs at least one key")
      }
      println(
        Json::array(doc.lookup_all(opts.words).map(text_value_json)).stringify(),
      )
    }
    _ => ()
  }
}

///|
fn text_value_json(value : @valve.Value) -> Json {
  match value {
    @valve.Text(s) => Json::string(s)
    @valve.Object(entries) => @valve.Document::{ entries, }.to_json()
  }
}

///|
fn shortcuts_json(file : @valve.ShortcutFile) -> Json raise {
  Json::array(
    file
    .shortcuts()
    .map(s => {
      Json::object({
        "index": Json::string(s.index),
        "app_id": Json::string(s.app_id.to_string()),
        "name": Json::string(s.name),
        "exe": Json::string(s.exe),
        "start_dir": Json::string(s.start_dir),
        "launch_options": Json::string(s.launch_options),
        "tags": Json::array(s.tags.map(Json::string)),
        "url": Json::string(s.url()),
      })
    }),
  )
}

///|
fn definition_text(
  fields : Map[String, Json],
  key : String,
  fallback : String,
) -> String raise CliError {
  match fields.get(key) {
    None => fallback
    Some(String(s)) => s
    _ => raise InvalidArgument("Expected text field: " + key)
  }
}

///|
fn run_shortcut_change(
  command : String,
  file : String,
  opts : CommandOptions,
) -> Unit raise {
  if opts.literal ||
    opts.resolve ||
    opts.root is Some(_) ||
    opts.symbols is Some(_) {
    raise InvalidArgument("Text options do not apply to shortcuts")
  }
  let needed = if command == "shortcut-set" { 2 } else { 1 }
  if opts.words.length() != needed {
    raise InvalidArgument("Unexpected shortcut arguments")
  }
  let before = host_read_bytes(file)
  let source = @valve.read_shortcut_file(@valve.decode_binary(before))
  let changed = if command == "shortcut-remove" {
    source.remove(opts.words[0])
  } else {
    let filename = opts.words[needed - 1]
    guard @json.parse(input_text(filename)[:]) is Object(fields) else {
      raise InvalidArgument("Shortcut definition must be an object")
    }
    for key, _ in fields {
      if !["name", "exe", "start_dir", "launch_options", "tags"].contains(key) {
        raise InvalidArgument("Unknown shortcut field: " + key)
      }
    }
    let old = if command == "shortcut-set" {
      source.shortcuts().iter().find_first(s => s.index == opts.words[0])
    } else {
      None
    }
    if command == "shortcut-set" && old is None {
      raise InvalidArgument("Shortcut index does not exist")
    }
    let name = definition_text(
      fields,
      "name",
      match old {
        Some(s) => s.name
        None => ""
      },
    )
    let exe = definition_text(
      fields,
      "exe",
      match old {
        Some(s) => s.exe
        None => ""
      },
    )
    let start_dir = definition_text(
      fields,
      "start_dir",
      match old {
        Some(s) => s.start_dir
        None => ""
      },
    )
    let launch_options = definition_text(
      fields,
      "launch_options",
      match old {
        Some(s) => s.launch_options
        None => ""
      },
    )
    let tags = match fields.get("tags") {
      None =>
        match old {
          Some(s) => s.tags
          None => []
        }
      Some(Array(tags)) =>
        tags.map(tag => {
          match tag {
            String(s) => s
            _ => raise InvalidArgument("Tags must be strings")
          }
        })
      _ => raise InvalidArgument("Tags must be an array")
    }
    match old {
      Some(s) =>
        source.set({ ..s, name, exe, start_dir, launch_options, tags, })
      None => source.add(name, exe, start_dir~, launch_options~, tags~)
    }
  }
  emit_changed(
    file,
    before,
    @valve.encode_binary(changed.to_binary()),
    opts,
    false,
  )
}
