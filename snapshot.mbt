///|
priv struct TextPatch {
  start : Int32
  end : Int32
  text : String
}

///|
fn index_key(path : Array[Int32]) -> String {
  path.map(i => i.to_string()).join("/")
}

///|
fn Document::indices(
  self : Document,
  path : Array[Selector],
) -> Array[Int32] raise EditError {
  if path.length() > 128 {
    raise InvalidEdit("Path exceeds 128 levels")
  }
  let result : Array[Int32] = []
  let mut value = Value::Object(self.entries)
  for selector in path {
    guard value is Object(entries) && selector.occurrence >= 0 else {
      raise InvalidEdit("Invalid path selector or scalar parent")
    }
    let mut seen = 0
    let mut found = false
    for i in 0..<entries.length() {
      if entries[i].key == selector.key {
        if seen == selector.occurrence {
          result.push(i)
          value = entries[i].value
          found = true
          break
        }
        seen += 1
      }
    }
    if !found {
      raise InvalidEdit("Snapshot path was not found")
    }
  }
  result
}

///|
fn snapshot_operations(
  document : Document,
  changes : Array[Change],
) -> Map[String, Edit] raise {
  if changes.length() > 10000 {
    raise InvalidEdit("Snapshot exceeds 10000 edits")
  }
  let wanted : Map[String, Edit] = Map([])
  for change in changes {
    if change.operation is Insert(_, _) {
      raise InvalidEdit("Snapshot edits support replace, rename and remove")
    }
    if change.path.is_empty() {
      raise InvalidEdit("Snapshot edits must select keyed entries")
    }
    if change.path.length() > 128 || change.path.any(p => p.occurrence < 0) {
      raise InvalidEdit("Invalid snapshot path")
    }
    let key = selector_key(change.path)
    if wanted.contains(key) {
      raise InvalidEdit("Duplicate snapshot target")
    }
    wanted[key] = change.operation
  }
  for change in changes {
    for depth in 1..<change.path.length() {
      if wanted.contains(selector_key(change.path[:depth].to_owned())) {
        raise InvalidEdit("Snapshot targets overlap as ancestor and descendant")
      }
    }
  }
  let result : Map[String, Edit] = Map([])
  collect_snapshot_targets(document.entries, "", "", wanted, result, 0)
  if result.length() != changes.length() {
    raise InvalidEdit("Snapshot path was not found")
  }
  result
}

///|
fn selector_component(selector : Selector) -> String {
  selector.key.length().to_string() +
  ":" +
  selector.key +
  "#" +
  selector.occurrence.to_string() +
  "/"
}

///|
fn selector_key(path : Array[Selector]) -> String {
  path.map(selector_component).join("")
}

///|
fn collect_snapshot_targets(
  entries : Array[Entry],
  selector_prefix : String,
  index_prefix : String,
  wanted : Map[String, Edit],
  result : Map[String, Edit],
  depth : Int32,
) -> Unit raise {
  if depth > 128 {
    raise InvalidEdit("Snapshot exceeds depth limit")
  }
  let seen : Map[String, Int32] = Map([])
  for i in 0..<entries.length() {
    let entry = entries[i]
    let occurrence = seen.get(entry.key).unwrap_or(0)
    seen[entry.key] = occurrence + 1
    let selector = selector_prefix +
      selector_component({ key: entry.key, occurrence, })
    let index = index_prefix + i.to_string()
    if wanted.get(selector) is Some(operation) {
      result[index] = operation
    }
    if entry.value is Object(children) {
      collect_snapshot_targets(
        children,
        selector,
        index + "/",
        wanted,
        result,
        depth + 1,
      )
    }
  }
}

///|
fn snapshot_entries(
  entries : Array[Entry],
  prefix : String,
  operations : Map[String, Edit],
  depth : Int32,
) -> Array[Entry] raise {
  if depth > 128 {
    raise InvalidEdit("Snapshot exceeds depth limit")
  }
  let output : Array[Entry] = []
  for i in 0..<entries.length() {
    let entry = entries[i]
    let key = prefix + i.to_string()
    match operations.get(key) {
      Some(Remove) => ()
      Some(Rename(name)) => output.push({ key: name, value: entry.value, })
      Some(Replace(value)) => output.push({ key: entry.key, value, })
      Some(Insert(_, _)) => raise InvalidEdit("Unsupported snapshot insertion")
      None => {
        let value = match entry.value {
          Object(children) =>
            Object(snapshot_entries(children, key + "/", operations, depth + 1))
          _ => entry.value
        }
        output.push({ key: entry.key, value, })
      }
    }
  }
  output
}

///|
pub fn Document::apply_snapshot(
  self : Document,
  changes : Array[Change],
) -> Document raise {
  let operations = snapshot_operations(self, changes)
  let result = Document::{
    entries: snapshot_entries(self.entries, "", operations, 0),
  }
  parse(stringify(result)) |> ignore
  result
}

///|
fn SourceDocument::patched(
  self : SourceDocument,
  patches : Array[TextPatch],
  expected : Document,
) -> SourceDocument raise {
  patches.sort_by((a, b) => a.start.compare(b.start))
  let output = StringBuilder()
  let mut cursor = 0
  for patch in patches {
    if patch.start < cursor ||
      patch.end < patch.start ||
      patch.end > self.chars.length() {
      raise InvalidEdit("Overlapping or invalid source patches")
    }
    output.write_string(
      String::from_array(self.chars[cursor:patch.start].to_owned()),
    )
    output.write_string(patch.text)
    cursor = patch.end
  }
  output.write_string(String::from_array(self.chars[cursor:].to_owned()))
  let result = parse_preserving(output.to_string(), options=self.options)
  if result.doc != expected {
    raise InvalidEdit("Source patches changed unintended semantics")
  }
  result
}

///|
/// All targets address the same original source; compile patches then parse once.
pub fn SourceDocument::apply_snapshot(
  self : SourceDocument,
  changes : Array[Change],
) -> SourceDocument raise {
  let operations = snapshot_operations(self.doc, changes)
  let expected = Document::{
    entries: snapshot_entries(self.doc.entries, "", operations, 0),
  }
  let patches : Array[TextPatch] = []
  for span in self.spans {
    guard operations.get(index_key(span.path)) is Some(operation) else {
      continue
    }
    let output = StringBuilder()
    let (start, end) = match operation {
      Remove => (span.key_start, span.entry_end)
      Rename(key) => {
        self.render_string(output, key, self.chars[span.key_start] == '"')
        (span.key_start, span.key_end)
      }
      Replace(Text(value)) => {
        self.render_string(output, value, self.chars[span.value_start] == '"')
        (span.value_start, span.value_end)
      }
      Replace(Object(children)) => {
        let indent = self.line_indent(span.key_start)
        output.write_string("{" + self.newline())
        self.render_entries(output, children, indent + self.indent_unit(), true)
        output.write_string(indent + "}")
        (span.value_start, span.value_end)
      }
      _ => raise InvalidEdit("Unsupported snapshot operation")
    }
    patches.push({ start, end, text: output.to_string(), })
  }
  self.patched(patches, expected)
}

///|
pub fn SourceDocument::edit_query(
  self : SourceDocument,
  expression : String,
  operation : QueryEdit,
) -> SourceDocument raise {
  self.apply_snapshot(self.doc.query_plan(expression, operation))
}
