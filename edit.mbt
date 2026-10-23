///|
/// Select the zero-based occurrence of a key, preserving duplicate siblings.
pub(all) struct Selector {
  key : String
  occurrence : Int
} derive(Eq, Debug)

///|
pub extend Selector with Eq::{equal, not_equal}

///|
pub extend Selector with @debug.Debug::{to_repr}

///|
pub(all) enum Edit {
  Replace(Value)
  Remove
  Rename(String)
  Insert(Int, Entry)
} derive(Debug)

///|
pub extend Edit with @debug.Debug::{to_repr}

///|
pub suberror EditError {
  InvalidEdit(String)
} derive(Debug)

///|
pub extend EditError with @debug.Debug::{to_repr}

///|
/// Return a changed document without modifying the input arrays. An empty
/// path selects the root object and supports Insert or Replace(Object(...)).
pub fn Document::edit(
  self : Document,
  path : Array[Selector],
  operation : Edit,
) -> Document raise EditError {
  if path.length() > 128 {
    raise InvalidEdit("Edit path exceeds 128 levels")
  }
  if path.is_empty() {
    match operation {
      Remove | Rename(_) =>
        raise InvalidEdit("The root has no key to remove or rename")
      _ => ()
    }
  }
  guard edit_value(Object(self.entries), path, 0, operation) is Object(entries) else {
    raise InvalidEdit("The document root must remain an object")
  }
  { entries, }
}

///|
fn edit_value(
  value : Value,
  path : Array[Selector],
  level : Int,
  operation : Edit,
) -> Value raise EditError {
  if level == path.length() {
    return match operation {
      Replace(replacement) => replacement
      Insert(index, entry) => {
        guard value is Object(entries) else {
          raise InvalidEdit("Insertion target is not an object")
        }
        if index < 0 || index > entries.length() {
          raise InvalidEdit("Insertion index is out of range")
        }
        let result : Array[Entry] = []
        for i in 0..<index {
          result.push(entries[i])
        }
        result.push(entry)
        for i in index..<entries.length() {
          result.push(entries[i])
        }
        Object(result)
      }
      _ => raise InvalidEdit("Removal and rename must select a keyed entry")
    }
  }
  guard value is Object(entries) else {
    raise InvalidEdit("Path crosses a text value")
  }
  let selector = path[level]
  if selector.occurrence < 0 {
    raise InvalidEdit("Occurrence must be nonnegative")
  }
  let mut seen = 0
  let mut found = false
  let result : Array[Entry] = []
  for entry in entries {
    let selected = entry.key == selector.key && seen == selector.occurrence
    if entry.key == selector.key {
      seen = seen + 1
    }
    if selected {
      found = true
      if level + 1 == path.length() {
        match operation {
          Remove => continue
          Rename(key) => {
            result.push({ key, value: entry.value, })
            continue
          }
          _ => ()
        }
      }
      result.push({
        key: entry.key,
        value: edit_value(entry.value, path, level + 1, operation),
      })
    } else {
      result.push(entry)
    }
  }
  if !found {
    raise InvalidEdit("Key occurrence was not found")
  }
  Object(result)
}
