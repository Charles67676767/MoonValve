///|
pub(all) struct Change {
  path : Array[Selector]
  operation : Edit
} derive(Debug)

///|
pub extend Change with @debug.Debug::{to_repr}

///|
/// Sequential paths address the result of the preceding change. A failed batch
/// never modifies the original document. Final output must satisfy text limits.
pub fn Document::apply(
  self : Document,
  changes : Array[Change],
  options? : ParseOptions = ParseOptions::default(),
) -> Document raise {
  if changes.length() > 10000 {
    raise InvalidEdit("A transaction supports at most 10000 changes")
  }
  let mut result = self
  for change in changes {
    result = result.edit(change.path, change.operation)
  }
  let text = stringify(result)
  parse(text, options~) |> ignore
  result
}

///|
/// Apply a batch to independent source snapshots; nothing is published on failure.
pub fn SourceDocument::apply(
  self : SourceDocument,
  changes : Array[Change],
) -> SourceDocument raise {
  if changes.length() > 10000 {
    raise InvalidEdit("A transaction supports at most 10000 changes")
  }
  let mut result = self
  for change in changes {
    result = result.edit(change.path, change.operation)
  }
  result
}

///|
/// Portable JSON plan: [{path:[{key,occurrence}],op,value/key/index/entry}].
/// Values and entries use the same ordered representation as Document::to_json.
pub fn changes_from_json(json : Json) -> Array[Change] raise {
  guard json is Array(rows) && rows.length() <= 10000 else {
    raise InvalidEdit("Expected an array of at most 10000 changes")
  }
  let result : Array[Change] = []
  for row in rows {
    guard row is Object(fields) &&
      fields.get("path") is Some(Array(raw_path)) &&
      fields.get("op") is Some(String(op)) else {
      raise InvalidEdit("Change requires path and op")
    }
    let path : Array[Selector] = []
    for selector in raw_path {
      guard selector is Object(s) &&
        s.length() == 2 &&
        s.get("key") is Some(String(key)) &&
        s.get("occurrence") is Some(Number(n, ..)) &&
        n >= 0 &&
        n <= 2147483647.0 &&
        n == n.to_int().to_double() else {
        raise InvalidEdit("Invalid path selector")
      }
      path.push({ key, occurrence: n.to_int(), })
    }
    if path.length() > 128 {
      raise InvalidEdit("Path exceeds 128 levels")
    }
    let operation = match op {
      "remove" => {
        if fields.length() != 2 {
          raise InvalidEdit("Unexpected remove fields")
        }
        Edit::Remove
      }
      "rename" => {
        guard fields.length() == 3 && fields.get("key") is Some(String(key)) else {
          raise InvalidEdit("rename requires key")
        }
        Rename(key)
      }
      "replace" => {
        guard fields.length() == 3 && fields.get("value") is Some(value) else {
          raise InvalidEdit("replace requires value")
        }
        Replace(plan_value(value))
      }
      "insert" => {
        guard fields.length() == 4 &&
          fields.get("index") is Some(Number(n, ..)) &&
          n >= 0 &&
          n <= 2147483647.0 &&
          n == n.to_int().to_double() &&
          fields.get("entry") is Some(entry) else {
          raise InvalidEdit("insert requires integer index and entry")
        }
        let doc = document_from_json(Json::array([entry]))
        Insert(n.to_int(), doc.entries[0])
      }
      _ => raise InvalidEdit("Unknown change operation: " + op)
    }
    result.push({ path, operation, })
  }
  result
}

///|
fn plan_value(json : Json) -> Value raise {
  match json {
    String(s) => Text(s)
    Array(_) => Object(document_from_json(json).entries)
    _ => raise InvalidEdit("Value must be text or an ordered entry array")
  }
}
