///|
fn raw_source(
  file : String,
  opts : CommandOptions,
) -> (Bytes, @valve.SourceDocument) raise {
  if opts.resolve || opts.symbols is Some(_) || opts.root is Some(_) {
    raise InvalidArgument("Source edits retain raw conditions and references")
  }
  let before = host_read_bytes(file)
  (
    before,
    @valve.parse_preserving(@utf8.decode(before[:]), options={
      ..@valve.ParseOptions::default(),
      escape_sequences: !opts.literal,
    }),
  )
}

///|
fn run_advanced(
  command : String,
  file : String,
  opts : CommandOptions,
) -> Bool raise {
  match command {
    "format-preserving" | "kv3-format-preserving" => {
      if !opts.words.is_empty() ||
        opts.resolve ||
        opts.root is Some(_) ||
        opts.symbols is Some(_) ||
        (command == "kv3-format-preserving" && opts.literal) {
        raise InvalidArgument(
          "Whitespace formatting retains raw conditions and takes no resolved view",
        )
      }
      let before = host_read_bytes(file)
      let text = @utf8.decode(before[:])
      let result = if command == "kv3-format-preserving" {
        @valve.parse_kv3_preserving(text, allow_headerless=opts.headerless)
        .format_preserving()
        .text()
      } else {
        @valve.parse_preserving(text, options={
          ..@valve.ParseOptions::default(),
          escape_sequences: !opts.literal,
        })
        .format_preserving()
        .text()
      }
      emit_changed(file, before, @utf8.encode(result[:]), opts, true)
    }
    "kv3-resources" => {
      reject_write_options(opts)
      if opts.words.length() > 1 ||
        opts.literal ||
        opts.resolve ||
        opts.root is Some(_) ||
        opts.symbols is Some(_) {
        raise InvalidArgument("kv3-resources FILE [ROOTS.json]")
      }
      let roots = if opts.words.is_empty() {
        []
      } else {
        @valve.resource_roots_from_json(
          @json.parse(input_text(opts.words[0])[:]),
        )
      }
      let source = @valve.parse_kv3_preserving(
        input_text(file),
        allow_headerless=opts.headerless,
      )
      host_output(
        @valve.resource_references_to_json(source.resources(roots~)).stringify() +
        "\n",
      )
    }
    "kv3-resource-edit" => {
      if opts.words.length() != 2 ||
        opts.literal ||
        opts.resolve ||
        opts.root is Some(_) ||
        opts.symbols is Some(_) {
        raise InvalidArgument("kv3-resource-edit FILE ROOTS.json MOVES.json")
      }
      let roots = @valve.resource_roots_from_json(
        @json.parse(input_text(opts.words[0])[:]),
      )
      guard @json.parse(input_text(opts.words[1])[:]) is Object(rows) else {
        raise InvalidArgument("Expected resource move map")
      }
      let moves : Map[String, String] = Map([])
      for from, value in rows {
        guard value is String(to) else {
          raise InvalidArgument("Expected destination path")
        }
        moves[from] = to
      }
      let before = host_read_bytes(file)
      let result = @valve.parse_kv3_preserving(
        @utf8.decode(before[:]),
        allow_headerless=opts.headerless,
      ).rewrite_resources(roots, moves)
      emit_changed(file, before, @utf8.encode(result.text()[:]), opts, true)
    }
    "select" => {
      reject_write_options(opts)
      if opts.words.length() != 1 {
        raise InvalidArgument("select requires one query expression")
      }
      host_output(
        @valve.located_values_to_json(
          selected_document(file, opts).select(opts.words[0]),
        ).stringify() +
        "\n",
      )
    }
    "query-edit" | "edit-snapshot" | "transfer" => {
      let expected = if command == "query-edit" { 2 } else { 1 }
      if opts.words.length() != expected {
        raise InvalidArgument("Expected query/operation or JSON plan filename")
      }
      let (before, source) = raw_source(file, opts)
      let plan = @json.parse(input_text(opts.words[expected - 1])[:])
      let result = match command {
        "query-edit" =>
          source.edit_query(opts.words[0], @valve.query_edit_from_json(plan))
        "edit-snapshot" => source.apply_snapshot(@valve.changes_from_json(plan))
        _ => source.transfer_json(plan)
      }
      emit_changed(file, before, @utf8.encode(result.text()[:]), opts, true)
    }
    "kv3-parse" | "kv3-format" | "kv3-from-json" => {
      reject_write_options(opts)
      if !opts.words.is_empty() ||
        opts.literal ||
        opts.resolve ||
        opts.symbols is Some(_) ||
        opts.root is Some(_) {
        raise InvalidArgument("KV3 commands do not accept KV1 options")
      }
      let text = input_text(file)
      if command == "kv3-from-json" {
        host_output(
          @valve.stringify_kv3(@valve.kv3_from_json(@json.parse(text[:]))),
        )
      } else {
        let document = @valve.parse_kv3(text, allow_headerless=opts.headerless)
        if command == "kv3-parse" {
          host_output(@valve.kv3_to_json(document).stringify() + "\n")
        } else {
          host_output(@valve.stringify_kv3(document))
        }
      }
    }
    "kv3-select" | "kv3-query-edit" => {
      let count = if command == "kv3-select" { 1 } else { 2 }
      if opts.words.length() != count ||
        opts.literal ||
        opts.resolve ||
        opts.root is Some(_) ||
        opts.symbols is Some(_) {
        raise InvalidArgument(
          "KV3 query expects an expression and optional operation file, without KV1 options",
        )
      }
      let before = host_read_bytes(file)
      let source = @valve.parse_kv3_preserving(
        @utf8.decode(before[:]),
        allow_headerless=opts.headerless,
      )
      if command == "kv3-select" {
        reject_write_options(opts)
        host_output(
          @valve.kv3_located_values_to_json(
            source.document().select(opts.words[0]),
          ).stringify() +
          "\n",
        )
      } else {
        let operation = @valve.kv3_query_edit_from_json(
          @json.parse(input_text(opts.words[1])[:]),
        )
        let edited = source.edit_query(opts.words[0], operation)
        emit_changed(file, before, @utf8.encode(edited.text()[:]), opts, true)
      }
    }
    "kv3-edit" => {
      if opts.words.length() != 1 ||
        opts.literal ||
        opts.resolve ||
        opts.root is Some(_) ||
        opts.symbols is Some(_) {
        raise InvalidArgument(
          "kv3-edit requires one JSON plan and no KV1 options",
        )
      }
      let before = host_read_bytes(file)
      let source = @valve.parse_kv3_preserving(
        @utf8.decode(before[:]),
        allow_headerless=opts.headerless,
      )
      let edited = source.apply_json(@json.parse(input_text(opts.words[0])[:]))
      emit_changed(file, before, @utf8.encode(edited.text()[:]), opts, true)
    }
    "workspace-export" | "workspace-zip" => {
      reject_write_options(opts)
      if (if command == "workspace-export" {
          opts.words.length() != 1
        } else {
          opts.words.length() > 1
        }) ||
        opts.resolve ||
        opts.root is Some(_) ||
        opts.symbols is Some(_) {
        raise InvalidArgument(
          "workspace-export SNAPSHOT NEW-DIRECTORY or workspace-zip SNAPSHOT",
        )
      }
      let snapshot = @json.parse(input_text(file)[:])
      let options = {
        ..@valve.ParseOptions::default(),
        escape_sequences: !opts.literal,
      }
      if command == "workspace-zip" {
        let bytes = @valve.export_project_zip(snapshot, options~)
        if opts.words.is_empty() {
          host_output_bytes(bytes)
          host_output_check()
        } else {
          host_write_new(opts.words[0], bytes)
        }
      } else {
        let files = @valve.project_export_files(snapshot, options~)
        host_export_directory(opts.words[0], files)
        host_output(
          Json::object({
            "directory": Json::string(opts.words[0]),
            "files": Json::number(files.length().to_double()),
          }).stringify() +
          "\n",
        )
      }
    }
    "workspace-query" | "workspace-kv3-query" => {
      reject_write_options(opts)
      if opts.words.length() < 1 ||
        opts.words.length() > 2 ||
        opts.resolve ||
        opts.root is Some(_) ||
        opts.symbols is Some(_) {
        raise InvalidArgument(
          "workspace-query requires an expression and optional selected-files JSON filename",
        )
      }
      let files : Array[String] = if opts.words.length() == 2 {
        guard @json.parse(input_text(opts.words[1])[:]) is Array(values) else {
          raise InvalidArgument("Expected a file list")
        }
        values.map(v => {
          guard v is String(s) else {
            raise InvalidArgument("Expected a filename")
          }
          s
        })
      } else {
        []
      }
      let snapshot = @json.parse(input_text(file)[:])
      let options = {
        ..@valve.ParseOptions::default(),
        escape_sequences: !opts.literal,
      }
      let result = if command == "workspace-kv3-query" {
        @valve.query_workspace_kv3_snapshot(
          snapshot,
          opts.words[0],
          files~,
          options~,
        )
      } else {
        @valve.query_workspace_snapshot(
          snapshot,
          opts.words[0],
          files~,
          options~,
        )
      }
      host_output(result.stringify() + "\n")
    }
    "workspace-edit" => {
      if opts.words.length() != 1 ||
        opts.resolve ||
        opts.root is Some(_) ||
        opts.symbols is Some(_) {
        raise InvalidArgument(
          "workspace-edit requires a snapshot and one JSON plan",
        )
      }
      let before = host_read_bytes(file)
      let snapshot = @json.parse(@utf8.decode(before[:])[:])
      let plan = @json.parse(input_text(opts.words[0])[:])
      let result = @valve.edit_workspace_snapshot(snapshot, plan, options={
        ..@valve.ParseOptions::default(),
        escape_sequences: !opts.literal,
      })
      emit_changed(
        file,
        before,
        @utf8.encode(result.stringify()[:]),
        opts,
        true,
      )
    }
    _ => return false
  }
  true
}
