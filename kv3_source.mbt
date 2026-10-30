///|
priv struct KV3Span {
  start : Int32
  end : Int32
  body : Int32
}

///|
struct KV3SourceDocument {
  source : String
  chars : Array[Char]
  doc : KV3Document
  options : ParseOptions
  spans : Map[String, KV3Span]
  keys : Map[String, (Int32, Int32)]
}

///|
pub(all) enum KV3Edit {
  KV3Replace(KV3Value)
  KV3Remove
  KV3Rename(String)
  KV3InsertField(Int32, String, KV3Value)
  KV3InsertElement(Int32, KV3Value)
} derive(Debug)

///|
pub extend KV3Edit with @debug.Debug::{to_repr}

///|
pub fn parse_kv3_preserving(
  input : String,
  options~ : ParseOptions = ParseOptions::default(),
  allow_headerless~ : Bool = false,
) -> KV3SourceDocument raise {
  let spans : Map[String, KV3Span] = Map([])
  let (doc, reader) = kv3_read(input, options, allow_headerless, Some(spans))
  {
    source: input,
    chars: reader.chars,
    doc,
    options,
    spans,
    keys: reader.keys,
  }
}

///|
pub fn KV3SourceDocument::text(self : KV3SourceDocument) -> String {
  self.source
}

///|
pub fn KV3SourceDocument::document(self : KV3SourceDocument) -> KV3Document {
  self.doc
}

///|
fn kv3_unflag(value : KV3Value) -> KV3Value {
  match value {
    KV3Flag(_, inner) => inner
    _ => value
  }
}

///|
fn KV3SourceDocument::indices(
  self : KV3SourceDocument,
  path : Array[String],
) -> Array[Int32] raise {
  if path.length() > 128 {
    raise InvalidEdit("KV3 path exceeds 128 components")
  }
  let indices : Array[Int32] = []
  let mut value = self.doc.root
  for component in path {
    match kv3_unflag(value) {
      KV3Object(entries) => {
        let mut found = false
        for i in 0..<entries.length() {
          if entries[i].key == component {
            indices.push(i)
            value = entries[i].value
            found = true
            break
          }
        }
        if !found {
          raise InvalidEdit("KV3 field was not found")
        }
      }
      KV3Array(values) => {
        let i = @strconv.parse_int(component[:]) catch {
          _ => raise InvalidEdit("Expected an array index")
        }
        if i < 0 || i >= values.length() || i.to_string() != component {
          raise InvalidEdit("Invalid KV3 array index")
        }
        indices.push(i)
        value = values[i]
      }
      _ => raise InvalidEdit("KV3 path traverses a scalar")
    }
  }
  indices
}

///|
fn kv3_at(value : KV3Value, path : Array[Int32]) -> KV3Value {
  if path.is_empty() {
    return value
  }
  let next = match kv3_unflag(value) {
    KV3Object(entries) => entries[path[0]].value
    KV3Array(values) => values[path[0]]
    _ => value
  }
  kv3_at(next, path[1:].to_owned())
}

///|
fn kv3_modified(
  value : KV3Value,
  path : Array[Int32],
  operation : KV3Edit,
) -> KV3Value raise {
  if path.is_empty() && operation is KV3Replace(replacement) {
    return replacement
  }
  if value is KV3Flag(flag, inner) {
    return KV3Flag(flag, kv3_modified(inner, path, operation))
  }
  match value {
    KV3Object(entries) => {
      let result : Array[KV3Entry] = []
      if path.is_empty() {
        guard operation is KV3InsertField(index, key, inserted) &&
          index >= 0 &&
          index <= entries.length() else {
          raise InvalidEdit("Expected a valid object insertion")
        }
        if entries.any(e => e.key == key) {
          raise InvalidEdit("Duplicate KV3 field")
        }
        for i in 0..<=entries.length() {
          if i == index {
            result.push({ key, value: inserted, })
          }
          if i < entries.length() {
            result.push(entries[i])
          }
        }
      } else {
        for i in 0..<entries.length() {
          let entry = entries[i]
          if i != path[0] {
            result.push(entry)
            continue
          }
          if path.length() == 1 {
            match operation {
              KV3Remove => continue
              KV3Rename(key) => {
                if entries.any(e => e.key == key) && key != entry.key {
                  raise InvalidEdit("Duplicate KV3 field")
                }
                result.push({ key, value: entry.value, })
                continue
              }
              _ => ()
            }
          }
          result.push({
            key: entry.key,
            value: kv3_modified(entry.value, path[1:].to_owned(), operation),
          })
        }
      }
      KV3Object(result)
    }
    KV3Array(values) => {
      let result : Array[KV3Value] = []
      if path.is_empty() {
        guard operation is KV3InsertElement(index, inserted) &&
          index >= 0 &&
          index <= values.length() else {
          raise InvalidEdit("Expected a valid array insertion")
        }
        for i in 0..<=values.length() {
          if i == index {
            result.push(inserted)
          }
          if i < values.length() {
            result.push(values[i])
          }
        }
      } else {
        for i in 0..<values.length() {
          if i != path[0] {
            result.push(values[i])
            continue
          }
          if path.length() == 1 && operation is KV3Remove {
            continue
          }
          if path.length() == 1 && operation is KV3Rename(_) {
            raise InvalidEdit("Array elements have no field names")
          }
          result.push(kv3_modified(values[i], path[1:].to_owned(), operation))
        }
      }
      KV3Array(result)
    }
    _ => raise InvalidEdit("Operation requires a container")
  }
}

///|
fn kv3_render(value : KV3Value, newline : String) -> String raise {
  // Validate constructed values before recursive rendering.
  let text = stringify_kv3({ header: None, root: value, })
  text[:text.length() - 1].to_owned().replace_all(old="\n", new=newline)
}

///|
fn KV3SourceDocument::comma(
  self : KV3SourceDocument,
  start : Int32,
  end : Int32,
) -> Int32? raise {
  let reader = KV3Reader::{
    chars: self.chars,
    options: self.options,
    pos: start,
    line: 1,
    column: 1,
    nodes: 0,
    path: [],
    spans: None,
    keys: Map([]),
  }
  reader.space()
  if reader.pos < end && reader.peek() == Some(',') {
    Some(reader.pos)
  } else {
    None
  }
}

///|
/// Path components are object keys or canonical decimal array indices. Flags
/// are transparent to traversal; replacing a flagged value replaces its flag too.
pub fn KV3SourceDocument::edit(
  self : KV3SourceDocument,
  path : Array[String],
  operation : KV3Edit,
) -> KV3SourceDocument raise {
  let indices = self.indices(path)
  if indices.is_empty() && (operation is KV3Remove || operation is KV3Rename(_)) {
    raise InvalidEdit("Cannot remove or rename the KV3 root")
  }
  let expected = KV3Document::{
    header: self.doc.header,
    root: kv3_modified(self.doc.root, indices, operation),
  }
  stringify_kv3(expected) |> ignore
  let span = self.spans[index_key(indices)]
  let patches : Array[TextPatch] = []
  let newline = if self.source.contains("\r\n") { "\r\n" } else { "\n" }
  match operation {
    KV3Replace(value) =>
      patches.push({
        start: span.start,
        end: span.end,
        text: kv3_render(value, newline),
      })
    KV3Rename(key) => {
      let (start, end) = self.keys[index_key(indices)]
      let output = StringBuilder()
      kv3_write_string(output, key)
      patches.push({ start, end, text: output.to_string(), })
    }
    KV3Remove => {
      let parent_path = indices[:indices.length() - 1].to_owned()
      let parent = kv3_unflag(kv3_at(self.doc.root, parent_path))
      let index = indices[indices.length() - 1]
      if parent is KV3Object(_) {
        let (start, _) = self.keys[index_key(indices)]
        patches.push({ start, end: span.end, text: "", })
      } else if parent is KV3Array(values) {
        patches.push({ start: span.start, end: span.end, text: "", })
        let parent_span = self.spans[index_key(parent_path)]
        let after = self.comma(
          span.end,
          if index + 1 < values.length() {
            self.spans[index_key(parent_path + [index + 1])].start
          } else {
            parent_span.end - 1
          },
        )
        let comma = if after is Some(_) {
          after
        } else if index > 0 {
          self.comma(
            self.spans[index_key(parent_path + [index - 1])].end,
            span.start,
          )
        } else {
          None
        }
        if comma is Some(at) {
          patches.push({ start: at, end: at + 1, text: "", })
        }
      }
    }
    KV3InsertField(index, key, value) => {
      guard kv3_unflag(kv3_at(self.doc.root, indices)) is KV3Object(entries) else {
        raise InvalidEdit("Not an object")
      }
      let at = if index < entries.length() {
        self.keys[index_key(indices + [index])].0
      } else {
        span.end - 1
      }
      let output = StringBuilder()
      kv3_write_string(output, key)
      let text = " " +
        output.to_string() +
        " = " +
        kv3_render(value, newline) +
        " "
      patches.push({ start: at, end: at, text, })
    }
    KV3InsertElement(index, value) => {
      guard kv3_unflag(kv3_at(self.doc.root, indices)) is KV3Array(values) else {
        raise InvalidEdit("Not an array")
      }
      let rendered = kv3_render(value, newline)
      if index < values.length() {
        let at = self.spans[index_key(indices + [index])].start
        patches.push({ start: at, end: at, text: rendered + ", ", })
      } else {
        if !values.is_empty() {
          let last = self.spans[index_key(indices + [values.length() - 1])]
          if self.comma(last.end, span.end - 1) is None {
            patches.push({ start: last.end, end: last.end, text: ",", })
          }
        }
        patches.push({
          start: span.end - 1,
          end: span.end - 1,
          text: " " + rendered + " ",
        })
      }
    }
  }
  self.patched(patches, expected)
}

///|
fn KV3SourceDocument::patched(
  self : KV3SourceDocument,
  patches : Array[TextPatch],
  expected : KV3Document,
) -> KV3SourceDocument raise {
  patches.sort_by((a, b) => a.start.compare(b.start))
  let output = StringBuilder()
  let mut cursor = 0
  for patch in patches {
    if patch.start < cursor {
      raise InvalidEdit("Overlapping KV3 patches")
    }
    output.write_string(
      String::from_array(self.chars[cursor:patch.start].to_owned()),
    )
    output.write_string(patch.text)
    cursor = patch.end
  }
  output.write_string(String::from_array(self.chars[cursor:].to_owned()))
  let result = parse_kv3_preserving(
    output.to_string(),
    options=self.options,
    allow_headerless=self.doc.header is None,
  )
  if result.doc != expected {
    raise InvalidEdit("KV3 edit changed unintended semantics")
  }
  result
}

///|
/// A bounded sequential transaction. No result is returned on any invalid step.
pub fn KV3SourceDocument::apply_json(
  self : KV3SourceDocument,
  plan : Json,
) -> KV3SourceDocument raise {
  guard plan is Array(steps) && steps.length() <= 1000 else {
    raise InvalidEdit("Expected at most 1000 KV3 operations")
  }
  let mut result = self
  for step in steps {
    guard step is Object(fields) &&
      fields.get("op") is Some(String(op)) &&
      fields.get("path") is Some(Array(parts)) else {
      raise InvalidEdit("KV3 edit requires op and path")
    }
    let path = parts.map(p => {
      guard p is String(s) else {
        raise InvalidEdit("KV3 path components must be strings")
      }
      s
    })
    let operation = match op {
      "remove" if fields.length() == 2 => KV3Remove
      "rename" if fields.length() == 3 && fields.get("key") is Some(String(key)) =>
        KV3Rename(key)
      "replace" if fields.length() == 3 && fields.get("value") is Some(value) =>
        KV3Replace(kv3_unpack(value, 0, { val: 0, }))
      "insert-field" | "insert-element" => {
        guard fields.length() == (if op == "insert-field" { 5 } else { 4 }) &&
          fields.get("index") is Some(Number(n, ..)) &&
          n >= 0.0 &&
          n <= 100000.0 &&
          n == n.to_int().to_double() &&
          fields.get("value") is Some(value) else {
          raise InvalidEdit("Invalid KV3 insertion")
        }
        let value = kv3_unpack(value, 0, { val: 0, })
        if op == "insert-field" {
          guard fields.get("key") is Some(String(key)) else {
            raise InvalidEdit("Expected a field name")
          }
          KV3InsertField(n.to_int(), key, value)
        } else {
          KV3InsertElement(n.to_int(), value)
        }
      }
      _ => raise InvalidEdit("Invalid KV3 operation fields")
    }
    result = result.edit(path, operation)
  }
  result
}

///|
/// Zero-based Unicode scalar offsets, suitable for UTF-16 conversion by hosts.
pub(all) struct KV3SourceRange {
  start : Int32
  end : Int32
  selection_start : Int32
  selection_end : Int32
} derive(Eq, Debug)

///|
pub extend KV3SourceRange with Eq::{equal, not_equal}

///|
pub extend KV3SourceRange with @debug.Debug::{to_repr}

///|
pub fn KV3SourceDocument::range(
  self : KV3SourceDocument,
  path : Array[String],
) -> KV3SourceRange raise {
  let indices = self.indices(path)
  let key = index_key(indices)
  let span = self.spans[key]
  let container = kv3_unflag(kv3_at(self.doc.root, indices)) is KV3Object(_) ||
    kv3_unflag(kv3_at(self.doc.root, indices)) is KV3Array(_)
  let (start, end) = self.keys
    .get(key)
    .unwrap_or(
      (
        if container {
          span.body
        } else {
          span.start
        },
        if container {
          span.body + 1
        } else {
          span.end
        },
      ),
    )
  { start, end: span.end, selection_start: start, selection_end: end, }
}
