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
    "workspace-query" => {
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
      let result = @valve.query_workspace_snapshot(
        @json.parse(input_text(file)[:]),
        opts.words[0],
        files~,
        options={
          ..@valve.ParseOptions::default(),
          escape_sequences: !opts.literal,
        },
      )
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
