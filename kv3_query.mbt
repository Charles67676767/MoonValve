///|
pub(all) struct KV3LocatedValue {
  path : Array[String]
  value : KV3Value
} derive(Eq, Debug)

///|
pub extend KV3LocatedValue with Eq::{equal, not_equal}

///|
pub extend KV3LocatedValue with @debug.Debug::{to_repr}

///|
priv enum KV3Predicate {
  KV3TypeFilter(String)
  KV3FlagFilter(String)
  KV3StringFilter(String, String)
  KV3ScalarFilter(String, KV3Value)
}

///|
struct KV3Query {
  path : Query
  predicates : Array[KV3Predicate]
}

///|
priv struct KV3Match {
  path : Array[String]
  indices : Array[Int32]
  value : KV3Value
}

///|
fn kv3_kind(value : KV3Value) -> String {
  match kv3_unflag(value) {
    KV3Null => "null"
    KV3Bool(_) => "bool"
    KV3Integer(_) => "integer"
    KV3Float(_) => "float"
    KV3String(_) => "string"
    KV3Blob(_) => "blob"
    KV3Object(_) => "object"
    KV3Array(_) => "array"
    KV3Flag(_, _) => "flag"
  }
}

///|
fn kv3_predicate_parts(text : String) -> Array[String] raise {
  let parts : Array[String] = []
  let chars = text.to_array()
  let mut quoted = false
  let mut escaped = false
  let mut start = 0
  for i in 0..<chars.length() {
    let c = chars[i]
    if quoted {
      if escaped {
        escaped = false
      } else if c == '\\' {
        escaped = true
      } else if c == '"' {
        quoted = false
      }
    } else if c == '"' {
      quoted = true
    } else if c == '&' {
      parts.push(String::from_array(chars[start:i].to_owned()))
      start = i + 1
    }
  }
  if quoted {
    raise InvalidQuery("Unclosed query string")
  }
  parts.push(String::from_array(chars[start:].to_owned()))
  if parts.length() > 8 {
    raise InvalidQuery("KV3 query exceeds eight filters")
  }
  parts
}

///|
/// Same path steps and escaping as KV1, with /0 array indices, typed predicates
/// and conjunctions. Numeric comparisons do not coerce integers into doubles.
pub fn compile_kv3_query(expression : String) -> KV3Query raise {
  if expression.char_length() > 4096 {
    raise InvalidQuery("KV3 query exceeds 4096 characters")
  }
  let (path, raw) = match expression.find("?") {
    Some(i) => (expression[:i].to_owned(), Some(expression[i + 1:].to_owned()))
    None => (expression, None)
  }
  let path = compile_query(path)
  for step in path.steps {
    if step is KeyStep(_, Some(_)) {
      raise InvalidQuery(
        "KV3 uses /0 array indices, not KV1 occurrence selectors",
      )
    }
  }
  let predicates : Array[KV3Predicate] = []
  if raw is Some(raw) {
    for part in kv3_predicate_parts(raw) {
      let text = part.trim().to_owned()
      if text.has_prefix("type=") {
        let kind = text[5:].to_owned()
        if ![
            "null", "bool", "integer", "float", "string", "blob", "object", "array",
          ].contains(kind) {
          raise InvalidQuery("Unknown KV3 type")
        }
        predicates.push(KV3TypeFilter(kind))
      } else if text.has_prefix("flag=") {
        let flag = text[5:].to_owned()
        if flag != "none" && !kv3_flag(flag) {
          raise InvalidQuery("Unknown KV3 flag")
        }
        predicates.push(KV3FlagFilter(flag.to_lower()))
      } else {
        let mut matched = false
        for op in ["==", "!=", "^=", "*=", "$=", ">=", "<=", ">", "<"] {
          if !text.has_prefix(op) {
            continue
          }
          let raw = text[op.length():].trim().to_owned()
          if ["^=", "*=", "$="].contains(op) {
            guard (@json.parse(raw[:]) catch {
                _ => raise InvalidQuery("String filter requires a JSON string")
              })
              is String(wanted) else {
              raise InvalidQuery("String filter requires a JSON string")
            }
            predicates.push(KV3StringFilter(op, wanted))
          } else {
            let wanted = parse_kv3(raw, allow_headerless=true) catch {
              _ => raise InvalidQuery("Invalid typed scalar filter")
            }
            if wanted.root is KV3Object(_) ||
              wanted.root is KV3Array(_) ||
              wanted.root is KV3Flag(_, _) ||
              wanted.root is KV3Blob(_) {
              raise InvalidQuery("Filter requires a scalar literal")
            }
            if [">=", "<=", ">", "<"].contains(op) &&
              !(wanted.root is KV3Integer(_) || wanted.root is KV3Float(_)) {
              raise InvalidQuery("Ordered filter requires an integer or float")
            }
            predicates.push(KV3ScalarFilter(op, wanted.root))
          }
          matched = true
          break
        }
        if !matched {
          raise InvalidQuery("Unknown KV3 filter")
        }
      }
    }
  }
  { path, predicates, }
}

///|
fn kv3_integer_parts(text : String) -> (Bool, String) {
  let negative = text.has_prefix("-")
  let digits = if negative || text.has_prefix("+") {
    text[1:].to_owned()
  } else {
    text
  }
  let chars = digits.to_array()
  let mut first = 0
  while first + 1 < chars.length() && chars[first] == '0' {
    first += 1
  }
  let digits = String::from_array(chars[first:].to_owned())
  (negative && digits != "0", digits)
}

///|
fn kv3_integer_compare(a : String, b : String) -> Int32 {
  let (an, av) = kv3_integer_parts(a)
  let (bn, bv) = kv3_integer_parts(b)
  if an != bn {
    return if an { -1 } else { 1 }
  }
  let cmp = if av.length() == bv.length() {
    av.lexical_compare(bv)
  } else {
    av.length().compare(bv.length())
  }
  if an {
    -cmp
  } else {
    cmp
  }
}

///|
fn kv3_scalar_order(a : KV3Value, b : KV3Value) -> Int32? {
  match (a, b) {
    (KV3Integer(a), KV3Integer(b)) => Some(kv3_integer_compare(a, b))
    (KV3Float(a), KV3Float(b)) => {
      let a = @strconv.parse_double(a[:]) catch { _ => return None }
      let b = @strconv.parse_double(b[:]) catch { _ => return None }
      if a.is_nan() || b.is_nan() || a.is_inf() || b.is_inf() {
        return None
      }
      Some(if a < b { -1 } else if a > b { 1 } else { 0 })
    }
    _ => None
  }
}

///|
fn KV3Query::accepts(self : KV3Query, value : KV3Value) -> Bool {
  let plain = kv3_unflag(value)
  for predicate in self.predicates {
    let accepted = match predicate {
      KV3TypeFilter(kind) => kv3_kind(plain) == kind
      KV3FlagFilter(flag) =>
        match value {
          KV3Flag(actual, _) => flag == actual
          _ => flag == "none"
        }
      KV3StringFilter(op, wanted) =>
        match plain {
          KV3String(text) =>
            match op {
              "^=" => text.has_prefix(wanted)
              "*=" => text.contains(wanted)
              _ => text.has_suffix(wanted)
            }
          _ => false
        }
      KV3ScalarFilter(op, wanted) => {
        let order = kv3_scalar_order(plain, wanted)
        if op == "==" || op == "!=" {
          let same = if order is Some(n) { n == 0 } else { plain == wanted }
          if op == "==" {
            same
          } else {
            !same
          }
        } else if order is Some(n) {
          match op {
            ">" => n > 0
            ">=" => n >= 0
            "<" => n < 0
            _ => n <= 0
          }
        } else {
          false
        }
      }
    }
    if !accepted {
      return false
    }
  }
  true
}

///|
fn KV3Query::walk(
  self : KV3Query,
  value : KV3Value,
  path : Array[String],
  indices : Array[Int32],
  states : Array[Bool],
  result : Array[KV3Match],
  visited : Ref[Int32],
  root : Bool,
) -> Unit raise {
  visited.val += 1
  if visited.val > 1000000 {
    raise InvalidQuery("KV3 query visit budget exceeded")
  }
  if (
      (!root && states[self.path.steps.length()]) ||
      (root && self.path.steps.is_empty())
    ) &&
    self.accepts(value) {
    if result.length() >= 10000 {
      raise InvalidQuery("KV3 query match budget exceeded")
    }
    result.push({ path: path.map(s => s), indices: indices.map(i => i), value, })
  }
  let children : Array[(String, KV3Value)] = match kv3_unflag(value) {
    KV3Object(entries) => entries.map(e => (e.key, e.value))
    KV3Array(values) => values.mapi((i, v) => (i.to_string(), v))
    _ => []
  }
  for i in 0..<children.length() {
    let (key, child) = children[i]
    let next = Array::make(states.length(), false)
    for j in 0..<self.path.steps.length() {
      if states[j] {
        match self.path.steps[j] {
          RecursiveStep => next[j] = true
          AnyStep => next[j + 1] = true
          KeyStep(wanted, _) => if wanted == key { next[j + 1] = true }
        }
      }
    }
    self.path.close_states(next)
    if !next.any(b => b) {
      continue
    }
    path.push(key)
    indices.push(i)
    self.walk(child, path, indices, next, result, visited, false)
    path.pop() |> ignore
    indices.pop() |> ignore
  }
}

///|
fn KV3Query::matches(
  self : KV3Query,
  document : KV3Document,
) -> Array[KV3Match] raise {
  // Validate public, caller-constructed trees and enforce depth/node budgets.
  kv3_check_size(document.root, 0, { val: 8387584, }, { val: 0, })
  let states = Array::make(self.path.steps.length() + 1, false)
  states[0] = true
  self.path.close_states(states)
  let result : Array[KV3Match] = []
  self.walk(document.root, [], [], states, result, { val: 0, }, true)
  result
}

///|
pub fn KV3Query::select(
  self : KV3Query,
  document : KV3Document,
) -> Array[KV3LocatedValue] raise {
  self.matches(document).map(row => { path: row.path, value: row.value, })
}

///|
pub fn KV3Document::select(
  self : KV3Document,
  expression : String,
) -> Array[KV3LocatedValue] raise {
  compile_kv3_query(expression).select(self)
}

///|
pub fn kv3_located_values_to_json(values : Array[KV3LocatedValue]) -> Json {
  Json::array(
    values.map(row => {
      Json::object({
        "path": Json::array(row.path.map(s => Json::string(s))),
        "value": kv3_pack(row.value),
      })
    }),
  )
}

///|
pub(all) enum KV3QueryEdit {
  KV3SetValue(KV3Value)
  KV3ReplacePrefix(String, String)
  KV3RenameMatches(String)
  KV3RemoveMatches
} derive(Debug)

///|
pub extend KV3QueryEdit with @debug.Debug::{to_repr}

///|
pub fn kv3_query_edit_from_json(json : Json) -> KV3QueryEdit raise {
  guard json is Object(fields) && fields.get("op") is Some(String(op)) else {
    raise InvalidQuery("Expected a KV3 query operation")
  }
  match op {
    "replace" if fields.length() == 2 && fields.get("value") is Some(value) =>
      KV3SetValue(kv3_unpack(value, 0, { val: 0, }))
    "replace-prefix" if fields.length() == 3 &&
      fields.get("from") is Some(String(from)) &&
      fields.get("to") is Some(String(to)) => KV3ReplacePrefix(from, to)
    "rename" if fields.length() == 2 && fields.get("key") is Some(String(key)) =>
      KV3RenameMatches(key)
    "remove" if fields.length() == 1 => KV3RemoveMatches
    _ => raise InvalidQuery("Invalid KV3 query operation fields")
  }
}

///|
fn kv3_prefix_value(
  value : KV3Value,
  from : String,
  to : String,
) -> KV3Value raise {
  match value {
    KV3Flag(flag, inner) => KV3Flag(flag, kv3_prefix_value(inner, from, to))
    KV3String(text) if text.has_prefix(from) =>
      KV3String(to + text[from.length():].to_owned())
    _ => raise InvalidQuery("Prefix edit selected a nonmatching string")
  }
}

///|
fn KV3SourceDocument::snapshot_value(
  self : KV3SourceDocument,
  value : KV3Value,
  path : Array[Int32],
  operations : Map[String, KV3Edit],
  patches : Array[TextPatch],
  newline : String,
) -> KV3Value raise {
  let key = index_key(path)
  if operations.get(key) is Some(KV3Replace(replacement)) {
    let span = self.spans[key]
    patches.push({
      start: span.start,
      end: span.end,
      text: kv3_render(replacement, newline),
    })
    return replacement
  }
  match value {
    KV3Flag(flag, inner) =>
      KV3Flag(
        flag,
        self.snapshot_value(inner, path, operations, patches, newline),
      )
    KV3Object(entries) => {
      let result : Array[KV3Entry] = []
      for i in 0..<entries.length() {
        let child_path = path + [i]
        let entry = entries[i]
        let op = operations.get(index_key(child_path))
        let (start, end) = self.keys[index_key(child_path)]
        let span = self.spans[index_key(child_path)]
        if op is Some(KV3Remove) {
          patches.push({ start, end: span.end, text: "", })
          continue
        }
        let name = if op is Some(KV3Rename(name)) {
          let out = StringBuilder()
          kv3_write_string(out, name)
          patches.push({ start, end, text: out.to_string(), })
          name
        } else {
          entry.key
        }
        result.push({
          key: name,
          value: self.snapshot_value(
            entry.value,
            child_path,
            operations,
            patches,
            newline,
          ),
        })
      }
      KV3Object(result)
    }
    KV3Array(values) => {
      let span = self.spans[key]
      let keep = values.mapi((i, _) => {
        !(operations.get(index_key(path + [i])) is Some(KV3Remove))
      })
      let last = if values.is_empty() {
        None
      } else {
        self.comma(
          self.spans[index_key(path + [values.length() - 1])].end,
          span.end - 1,
        )
      }
      let mut remaining = keep.filter(b => b).length()
      let result : Array[KV3Value] = []
      for i in 0..<values.length() {
        let child_path = path + [i]
        let child_span = self.spans[index_key(child_path)]
        if keep[i] {
          remaining -= 1
          if operations.get(index_key(child_path)) is Some(KV3Rename(_)) {
            raise InvalidQuery("Cannot rename an array element")
          }
          result.push(
            self.snapshot_value(
              values[i],
              child_path,
              operations,
              patches,
              newline,
            ),
          )
        } else {
          patches.push({
            start: child_span.start,
            end: child_span.end,
            text: "",
          })
        }
        let comma = self.comma(
          child_span.end,
          if i + 1 < values.length() {
            self.spans[index_key(path + [i + 1])].start
          } else {
            span.end - 1
          },
        )
        if comma is Some(at) && (!keep[i] || (remaining == 0 && last is None)) {
          patches.push({ start: at, end: at + 1, text: "", })
        }
      }
      KV3Array(result)
    }
    _ => value
  }
}

///|
/// All matched paths address the original source. Ancestor overlaps and rename
/// collisions fail the whole edit; unaffected tokens and trivia remain unchanged.
pub fn KV3SourceDocument::edit_query(
  self : KV3SourceDocument,
  expression : String,
  operation : KV3QueryEdit,
) -> KV3SourceDocument raise {
  let rows = compile_kv3_query(expression).matches(self.doc)
  let operations : Map[String, KV3Edit] = Map([])
  for row in rows {
    if row.indices.is_empty() &&
      !(operation is KV3SetValue(_) || operation is KV3ReplacePrefix(_, _)) {
      raise InvalidQuery("Cannot remove or rename root")
    }
    operations[index_key(row.indices)] = match operation {
      KV3SetValue(value) => KV3Replace(value)
      KV3ReplacePrefix(from, to) =>
        KV3Replace(kv3_prefix_value(row.value, from, to))
      KV3RenameMatches(key) => KV3Rename(key)
      KV3RemoveMatches => KV3Remove
    }
  }
  for row in rows {
    for depth in 0..<row.indices.length() {
      if operations.contains(index_key(row.indices[:depth].to_owned())) {
        raise InvalidQuery("Query targets overlap as ancestor and descendant")
      }
    }
  }
  let patches : Array[TextPatch] = []
  let newline = if self.source.contains("\r\n") { "\r\n" } else { "\n" }
  let root = self.snapshot_value(
    self.doc.root,
    [],
    operations,
    patches,
    newline,
  )
  let expected = KV3Document::{ header: self.doc.header, root, }
  stringify_kv3(expected) |> ignore
  self.patched(patches, expected)
}
