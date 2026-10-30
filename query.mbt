///|
pub suberror QueryError {
  InvalidQuery(String)
} derive(Debug)

///|
pub extend QueryError with @debug.Debug::{to_repr}

///|
priv enum QueryStep {
  KeyStep(String, Int32?)
  AnyStep
  RecursiveStep
}

///|
priv enum QueryFilter {
  AllValues
  TextFilter(String, String)
  KindFilter(Bool)
  NumberFilter(String, Double)
}

///|
/// Compiled, duplicate-aware path expression; not a JSONPath implementation.
struct Query {
  steps : Array[QueryStep]
  filter : QueryFilter
}

///|
fn query_unescape(text : String) -> String raise QueryError {
  let chars = text.to_array()
  let output = StringBuilder()
  let mut i = 0
  while i < chars.length() {
    if chars[i] == '~' {
      i += 1
      if i >= chars.length() {
        raise InvalidQuery("Incomplete key escape")
      }
      output.write_char(
        match chars[i] {
          '0' => '~'
          '1' => '/'
          '2' => '*'
          '3' => '['
          '4' => ']'
          '5' => '?'
          _ => raise InvalidQuery("Unknown key escape")
        },
      )
    } else {
      output.write_char(chars[i])
    }
    i += 1
  }
  output.to_string()
}

///|
pub fn compile_query(expression : String) -> Query raise QueryError {
  if expression.char_length() > 4096 {
    raise InvalidQuery("Query exceeds 4096 characters")
  }
  let (path, predicate) = match expression.find("?") {
    Some(i) => (expression[:i].to_owned(), expression[i + 1:].to_owned())
    None => (expression, "")
  }
  let steps : Array[QueryStep] = []
  if path != "$" {
    if !path.has_prefix("/") {
      raise InvalidQuery("Start paths with /, or use $ for the root")
    }
    for segment in path[1:].split("/") {
      let raw = segment.to_owned()
      let step = if raw == "*" {
        AnyStep
      } else if raw == "**" {
        RecursiveStep
      } else {
        let (key, occurrence) = if raw.has_suffix("]") &&
          raw.rev_find("[") is Some(i) {
          let index = raw[i + 1:raw.length() - 1].to_owned()
          if !decimal_id(index) {
            raise InvalidQuery(
              "Occurrence must be a nonnegative decimal integer",
            )
          }
          let n = @strconv.parse_int(index[:]) catch {
            _ => raise InvalidQuery("Occurrence is out of range")
          }
          (raw[:i].to_owned(), Some(n))
        } else {
          (raw, None)
        }
        if key.contains("[") || key.contains("]") {
          raise InvalidQuery("Escape literal brackets with ~3 and ~4")
        }
        KeyStep(query_unescape(key), occurrence)
      }
      steps.push(step)
      if steps.length() > 128 {
        raise InvalidQuery("Query exceeds 128 path steps")
      }
    }
  }
  let filter = if predicate == "" {
    if expression.contains("?") {
      raise InvalidQuery("Empty value filter")
    }
    AllValues
  } else if predicate == "kind=text" {
    KindFilter(true)
  } else if predicate == "kind=object" {
    KindFilter(false)
  } else {
    let mut found : QueryFilter? = None
    for op in ["==", "!=", "^=", "*=", "$=", ">=", "<=", ">", "<"] {
      if predicate.has_prefix(op) {
        let raw = predicate[op.length():].trim().to_owned()
        if [">=", "<=", ">", "<"].contains(op) {
          let number = @strconv.parse_double(raw[:]) catch {
            _ => raise InvalidQuery("Expected finite numeric filter")
          }
          if raw.is_empty() || number.is_nan() || number.is_inf() {
            raise InvalidQuery("Expected finite numeric filter")
          }
          found = Some(NumberFilter(op, number))
        } else {
          guard (@json.parse(raw[:]) catch {
              _ => raise InvalidQuery("Text filters require a JSON string")
            })
            is String(value) else {
            raise InvalidQuery("Text filters require a JSON string")
          }
          found = Some(TextFilter(op, value))
        }
        break
      }
    }
    guard found is Some(filter) else {
      raise InvalidQuery("Unknown filter operator")
    }
    filter
  }
  { steps, filter, }
}

///|
fn Query::accepts(self : Query, value : Value) -> Bool {
  match (self.filter, value) {
    (AllValues, _) => true
    (KindFilter(text), _) => text == (value is Text(_))
    (TextFilter(op, wanted), Text(text)) =>
      match op {
        "==" => text == wanted
        "!=" => text != wanted
        "^=" => text.has_prefix(wanted)
        "*=" => text.contains(wanted)
        _ => text.has_suffix(wanted)
      }
    (NumberFilter(op, wanted), Text(text)) => {
      if text.is_empty() || text.trim().to_owned() != text {
        return false
      }
      let number = @strconv.parse_double(text[:]) catch { _ => return false }
      if number.is_nan() || number.is_inf() {
        return false
      }
      match op {
        ">" => number > wanted
        ">=" => number >= wanted
        "<" => number < wanted
        _ => number <= wanted
      }
    }
    _ => false
  }
}

///|
fn Query::close_states(self : Query, states : Array[Bool]) -> Unit {
  for i in 0..<self.steps.length() {
    if states[i] && self.steps[i] is RecursiveStep {
      states[i + 1] = true
    }
  }
}

///|
pub fn Query::select(
  self : Query,
  document : Document,
  max_matches~ : Int32 = 10000,
  max_visited~ : Int32 = 1000000,
) -> Array[LocatedValue] raise {
  if max_matches < 1 ||
    max_matches > 100000 ||
    max_visited < 1 ||
    max_visited > 10000000 {
    raise InvalidQuery("Invalid query resource limits")
  }
  let states = Array::make(self.steps.length() + 1, false)
  states[0] = true
  self.close_states(states)
  let result : Array[LocatedValue] = []
  if self.steps.is_empty() {
    let value = Value::Object(document.entries)
    if self.accepts(value) {
      result.push({ path: [], value, })
    }
  } else {
    let visited : Ref[Int32] = { val: 0, }
    self.select_entries(
      document.entries,
      [],
      states,
      result,
      visited,
      max_matches,
      max_visited,
    )
  }
  result
}

///|
fn Query::select_entries(
  self : Query,
  entries : Array[Entry],
  path : Array[Selector],
  states : Array[Bool],
  result : Array[LocatedValue],
  visited : Ref[Int32],
  max_matches : Int32,
  max_visited : Int32,
) -> Unit raise {
  if path.length() >= 128 {
    raise InvalidQuery("Document exceeds query depth limit")
  }
  let occurrences : Map[String, Int32] = Map([])
  for entry in entries {
    visited.val += 1
    if visited.val > max_visited {
      raise InvalidQuery("Query visit budget exceeded")
    }
    let occurrence = occurrences.get(entry.key).unwrap_or(0)
    occurrences[entry.key] = occurrence + 1
    let next = Array::make(self.steps.length() + 1, false)
    for i in 0..<self.steps.length() {
      if states[i] {
        match self.steps[i] {
          RecursiveStep => next[i] = true
          AnyStep => next[i + 1] = true
          KeyStep(key, selected) =>
            if key == entry.key &&
              (selected is None || selected == Some(occurrence)) {
              next[i + 1] = true
            }
        }
      }
    }
    self.close_states(next)
    path.push({ key: entry.key, occurrence, })
    if next[self.steps.length()] && self.accepts(entry.value) {
      if result.length() >= max_matches {
        raise InvalidQuery("Query match budget exceeded")
      }
      result.push({ path: path.map(p => p), value: entry.value, })
    }
    if entry.value is Object(children) && next[:self.steps.length()].any(b => b) {
      self.select_entries(
        children, path, next, result, visited, max_matches, max_visited,
      )
    }
    path.pop() |> ignore
  }
}

///|
pub fn Document::select(
  self : Document,
  expression : String,
) -> Array[LocatedValue] raise {
  compile_query(expression).select(self)
}

///|
pub fn located_values_to_json(values : Array[LocatedValue]) -> Json {
  Json::array(
    values.map(row => {
      Json::object({
        "path": Json::array(
          row.path.map(p => {
            Json::object({
              "key": Json::string(p.key),
              "occurrence": Json::number(p.occurrence.to_double()),
            })
          }),
        ),
        "value": match row.value {
          Text(s) => Json::string(s)
          Object(entries) => entries_to_json(entries)
        },
      })
    }),
  )
}

///|
pub(all) enum QueryEdit {
  SetText(String)
  ReplacePrefix(String, String)
  RenameKey(String)
  RemoveMatches
} derive(Debug)

///|
pub extend QueryEdit with @debug.Debug::{to_repr}

///|
pub fn query_edit_from_json(json : Json) -> QueryEdit raise {
  guard json is Object(fields) && fields.get("op") is Some(String(op)) else {
    raise InvalidQuery("Query edit requires an operation object")
  }
  match op {
    "remove" if fields.length() == 1 => RemoveMatches
    "replace" | "rename" if fields.length() == 2 &&
      fields.get("value") is Some(String(value)) =>
      if op == "replace" {
        SetText(value)
      } else {
        RenameKey(value)
      }
    "replace-prefix" if fields.length() == 3 &&
      fields.get("from") is Some(String(from)) &&
      fields.get("to") is Some(String(to)) => ReplacePrefix(from, to)
    _ => raise InvalidQuery("Invalid query edit fields")
  }
}

///|
/// Plans address one original snapshot. Use apply_snapshot, not sequential apply.
pub fn Document::query_plan(
  self : Document,
  expression : String,
  operation : QueryEdit,
) -> Array[Change] raise {
  self
  .select(expression)
  .map(row => {
    let operation = match operation {
      SetText(text) => {
        guard row.value is Text(_) else {
          raise InvalidQuery("Text replacement selected an object")
        }
        Edit::Replace(Text(text))
      }
      ReplacePrefix(from, to) => {
        guard row.value is Text(text) && text.has_prefix(from) else {
          raise InvalidQuery(
            "Prefix replacement selected an incompatible value",
          )
        }
        Edit::Replace(Text(to + text[from.length():].to_owned()))
      }
      RenameKey(key) => Edit::Rename(key)
      RemoveMatches => Edit::Remove
    }
    { path: row.path, operation, }
  })
}
