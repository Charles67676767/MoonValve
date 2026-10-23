///|
pub suberror JsonImportError {
  InvalidJsonDocument(String)
} derive(Debug)

///|
pub extend JsonImportError with @debug.Debug::{to_repr}

///|
/// Decode the ordered [{key,value}] representation emitted by to_json.
pub fn document_from_json(
  value : Json,
  options? : ParseOptions = ParseOptions::default(),
) -> Document raise JsonImportError {
  if options.max_depth < 0 ||
    options.max_depth > 256 ||
    options.max_entries < 0 ||
    options.max_token_chars < 0 {
    raise InvalidJsonDocument("Invalid resource limits")
  }
  let count = Ref(0)
  { entries: import_entries(value, options, 0, count), }
}

///|
pub fn parse_json_document(
  text : String,
  options? : ParseOptions = ParseOptions::default(),
) -> Document raise JsonImportError {
  if options.max_input_chars < 0 || text.char_length() > options.max_input_chars {
    raise InvalidJsonDocument("JSON input exceeds max_input_chars")
  }
  let value = @json.parse(text[:]) catch {
    _ => raise InvalidJsonDocument("Invalid JSON syntax or excessive nesting")
  }
  document_from_json(value, options~)
}

///|
fn import_entries(
  value : Json,
  options : ParseOptions,
  depth : Int,
  count : Ref[Int],
) -> Array[Entry] raise JsonImportError {
  if depth > options.max_depth {
    raise InvalidJsonDocument("JSON document exceeds max_depth")
  }
  guard value is Array(items) else {
    raise InvalidJsonDocument("An object must be an ordered entry array")
  }
  let entries : Array[Entry] = []
  for item in items {
    if count.val >= options.max_entries {
      raise InvalidJsonDocument("JSON document exceeds max_entries")
    }
    count.val = count.val + 1
    guard item is Object(fields) else {
      raise InvalidJsonDocument("Each entry must be an object")
    }
    for key, _ in fields {
      if key != "key" && key != "value" {
        raise InvalidJsonDocument("Unknown entry field: " + key)
      }
    }
    guard fields.get("key") is Some(String(key)) else {
      raise InvalidJsonDocument("Entry key must be a string")
    }
    guard fields.get("value") is Some(raw) else {
      raise InvalidJsonDocument("Entry value is required")
    }
    check_import_text(key, options)
    let value = match raw {
      String(text) => {
        check_import_text(text, options)
        Value::Text(text)
      }
      Array(_) => Value::Object(import_entries(raw, options, depth + 1, count))
      _ =>
        raise InvalidJsonDocument(
          "Entry value must be a string or an entry array",
        )
    }
    entries.push({ key, value, })
  }
  entries
}

///|
fn check_import_text(
  text : String,
  options : ParseOptions,
) -> Unit raise JsonImportError {
  if text.char_length() > options.max_token_chars {
    raise InvalidJsonDocument("JSON string exceeds max_token_chars")
  }
  if text.any(c => c.to_int() == 0) {
    raise InvalidJsonDocument("NUL cannot appear in KV1 strings")
  }
}
