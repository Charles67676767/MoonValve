///|
/// A KeyValues value. Objects are ordered lists, so duplicate keys are retained.
pub(all) enum Value {
  Text(String)
  Object(Array[Entry])
} derive(Eq, Debug)

///|
/// One key-value pair, in source order.
pub(all) struct Entry {
  key : String
  value : Value
} derive(Eq, Debug)

///|
/// A document can contain zero, one, or several top-level entries.
pub(all) struct Document {
  entries : Array[Entry]
} derive(Eq, Debug)

///|
/// Parsing limits apply to the whole document; depth counts nested objects.
pub(all) struct ParseOptions {
  escape_sequences : Bool
  max_depth : Int32
  max_entries : Int32
  max_input_chars : Int32
  max_token_chars : Int32
  conditions : Array[String]?
} derive(Eq, Debug)

///|
/// Escapes are enabled for canonical output and Steam's escaped Windows paths.
pub fn ParseOptions::default() -> ParseOptions {
  {
    escape_sequences: true,
    max_depth: 128,
    max_entries: 100000,
    max_input_chars: 8388608,
    max_token_chars: 1048576,
    conditions: None,
  }
}

///|
/// Offset is a zero-based Unicode scalar index; line and column are one-based.
pub(all) struct Diagnostic {
  code : String
  message : String
  offset : Int32
  line : Int32
  column : Int32
} derive(Eq, Debug)

///|
pub suberror ParseError {
  ParseError(Diagnostic)
} derive(Debug)

///|
/// Look up the first exact, case-sensitive key match.
pub fn Document::get(self : Document, key : String) -> Value? {
  find_entry(self.entries, key)
}

///|
/// Look up every exact key match in source order.
pub fn Document::get_all(self : Document, key : String) -> Array[Value] {
  self.entries.filter_map(e => if e.key == key { Some(e.value) } else { None })
}

///|
/// Walk object keys. At each level, the first duplicate wins.
/// An empty path addresses the document's top-level object.
pub fn Document::lookup(self : Document, path : Array[String]) -> Value? {
  let mut current = Value::Object(self.entries)
  for key in path {
    match current {
      Object(entries) =>
        match find_entry(entries, key) {
          Some(value) => current = value
          None => return None
        }
      Text(_) => return None
    }
  }
  Some(current)
}

///|
pub fn Value::as_text(self : Value) -> String? {
  match self {
    Text(s) => Some(s)
    Object(_) => None
  }
}

///|
pub fn Value::as_object(self : Value) -> Array[Entry]? {
  match self {
    Object(entries) => Some(entries)
    Text(_) => None
  }
}

///|
/// Lossless JSON representation: ordered arrays of {key,value} entries.
/// An ordinary JSON object would silently lose duplicate keys.
pub fn Document::to_json(self : Document) -> Json {
  entries_to_json(self.entries)
}

///|
fn entries_to_json(entries : Array[Entry]) -> Json {
  Json::array(
    entries.map(e => {
      let fields : Map[String, Json] = Map([])
      fields["key"] = Json::string(e.key)
      fields["value"] = match e.value {
        Text(s) => Json::string(s)
        Object(children) => entries_to_json(children)
      }
      Json::object(fields)
    }),
  )
}

///|
fn find_entry(entries : Array[Entry], key : String) -> Value? {
  for entry in entries {
    if entry.key == key {
      return Some(entry.value)
    }
  }
  None
}
