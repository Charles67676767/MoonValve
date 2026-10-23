///|
pub suberror AccessError {
  InvalidAccess(Array[Selector], String)
} derive(Debug)

///|
pub extend AccessError with @debug.Debug::{to_repr}

///|
pub(all) struct LocatedValue {
  path : Array[Selector]
  value : Value
} derive(Eq, Debug)

///|
pub extend LocatedValue with Eq::{equal, not_equal}

///|
pub extend LocatedValue with @debug.Debug::{to_repr}

///|
/// Exact, duplicate-aware lookup. Errors retain the complete requested path.
pub fn Document::lookup_at(
  self : Document,
  path : Array[Selector],
) -> Value raise AccessError {
  if path.length() > 128 {
    raise InvalidAccess(path, "Path exceeds 128 levels")
  }
  let mut current = Value::Object(self.entries)
  for selector in path {
    if selector.occurrence < 0 {
      raise InvalidAccess(path, "Negative occurrence")
    }
    guard current is Object(entries) else {
      raise InvalidAccess(path, "Path crosses a scalar")
    }
    let mut count = 0
    let mut found = None
    for entry in entries {
      if entry.key == selector.key {
        if count == selector.occurrence {
          found = Some(entry.value)
          break
        }
        count += 1
      }
    }
    guard found is Some(value) else {
      raise InvalidAccess(path, "Path does not exist")
    }
    current = value
  }
  current
}

///|
/// Follow every matching duplicate at every level, retaining document order.
pub fn Document::lookup_all(
  self : Document,
  path : Array[String],
) -> Array[Value] raise AccessError {
  if path.length() > 128 {
    raise InvalidAccess([], "Path exceeds 128 levels")
  }
  let mut current = [Value::Object(self.entries)]
  for key in path {
    let next : Array[Value] = []
    for value in current {
      if value is Object(entries) {
        for entry in entries {
          if entry.key == key {
            next.push(entry.value)
          }
        }
      }
    }
    current = next
  }
  current
}

///|
/// Preorder visitor; returning false skips this object's descendants. Paths are
/// independent snapshots. The root itself is not emitted. Exceptions propagate.
pub fn Document::walk(
  self : Document,
  visitor : (Array[Selector], Value) -> Bool raise,
) -> Unit raise {
  walk_values(self.entries, [], visitor)
}

///|
fn walk_values(
  entries : Array[Entry],
  path : Array[Selector],
  visitor : (Array[Selector], Value) -> Bool raise,
) -> Unit raise {
  if path.length() > 128 {
    raise InvalidAccess(path, "Traversal exceeds 128 levels")
  }
  let occurrences : Map[String, Int] = Map([])
  for entry in entries {
    let occurrence = occurrences.get(entry.key).unwrap_or(0)
    occurrences[entry.key] = occurrence + 1
    let next = [..path, Selector::{ key: entry.key, occurrence, }]
    if visitor(next.map(s => s), entry.value) {
      if entry.value is Object(children) {
        walk_values(children, next, visitor)
      }
    }
  }
}

///|
pub fn Document::find(
  self : Document,
  key : String,
) -> Array[LocatedValue] raise {
  let result : Array[LocatedValue] = []
  self.walk((path, value) => {
    if path[path.length() - 1].key == key {
      result.push({ path, value, })
    }
    true
  })
  result
}

///|
pub fn Document::read_text(
  self : Document,
  path : Array[Selector],
) -> String raise AccessError {
  guard self.lookup_at(path) is Text(text) else {
    raise InvalidAccess(path, "Expected a text value")
  }
  text
}

///|
pub fn Document::read_int64(
  self : Document,
  path : Array[Selector],
) -> Int64 raise AccessError {
  let text = self.read_text(path)
  let digits = if text.has_prefix("-") { text[1:].to_owned() } else { text }
  if !decimal_id(digits) {
    raise InvalidAccess(path, "Expected a signed decimal Int64")
  }
  @strconv.parse_int64(text[:]) catch {
    _ => raise InvalidAccess(path, "Int64 is out of range")
  }
}

///|
pub fn Document::read_bool(
  self : Document,
  path : Array[Selector],
) -> Bool raise AccessError {
  match self.read_text(path) {
    "true" | "1" => true
    "false" | "0" => false
    _ => raise InvalidAccess(path, "Expected true, false, 1 or 0")
  }
}

///|
pub fn Document::read_double(
  self : Document,
  path : Array[Selector],
) -> Double raise AccessError {
  let text = self.read_text(path)
  if text.is_empty() || text.trim().to_owned() != text {
    raise InvalidAccess(path, "Expected a finite decimal number")
  }
  let n = @strconv.parse_double(text[:]) catch {
    _ => raise InvalidAccess(path, "Expected a finite decimal number")
  }
  if n.is_inf() || n.is_nan() {
    raise InvalidAccess(path, "Expected a finite decimal number")
  }
  n
}
