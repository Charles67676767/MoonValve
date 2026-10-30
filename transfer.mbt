///|
fn is_prefix_path(parent : Array[Int32], child : Array[Int32]) -> Bool {
  parent.length() <= child.length() &&
  parent == child[:parent.length()].to_owned()
}

///|
fn transfer_entries(
  entries : Array[Entry],
  path : Array[Int32],
  source : Array[Int32],
  target : Array[Int32],
  index : Int32,
  copy : Bool,
  inserted : Entry,
) -> Array[Entry] {
  let output : Array[Entry] = []
  for i in 0..<=entries.length() {
    if path == target && i == index {
      output.push(inserted)
    }
    if i == entries.length() {
      break
    }
    let next = [..path, i]
    if !copy && next == source {
      continue
    }
    let entry = entries[i]
    let value = match entry.value {
      Object(children) =>
        Object(
          transfer_entries(
            children, next, source, target, index, copy, inserted,
          ),
        )
      _ => entry.value
    }
    output.push({ key: entry.key, value, })
  }
  output
}

///|
/// Index is a boundary in the original destination object, before removal.
/// Moving into oneself/descendants is rejected. Copying produces a finite snapshot.
pub fn Document::transfer(
  self : Document,
  from : Array[Selector],
  to : Array[Selector],
  index : Int32,
  copy~ : Bool = false,
) -> Document raise {
  if from.is_empty() {
    raise InvalidEdit("The root cannot be transferred")
  }
  let source = self.indices(from)
  let target = self.indices(to)
  if is_prefix_path(source, target) {
    raise InvalidEdit("Cannot transfer into the source subtree")
  }
  guard self.lookup_at(to) is Object(children) else {
    raise InvalidEdit("Destination must be an object")
  }
  if index < 0 || index > children.length() {
    raise InvalidEdit("Destination index out of range")
  }
  let selected = self.lookup_at(from)
  let entry = Entry::{ key: from[from.length() - 1].key, value: selected, }
  {
    entries: transfer_entries(
      self.entries,
      [],
      source,
      target,
      index,
      copy,
      entry,
    ),
  }
}

///|
fn SourceDocument::line_start(self : SourceDocument, offset : Int32) -> Int32 {
  let mut start = offset
  while start > 0 &&
        self.chars[start - 1] != '\n' &&
        self.chars[start - 1] != '\r' {
    start -= 1
  }
  start
}

///|
/// Attach contiguous preceding // lines, except the document preamble.
/// A same-line trailing // comment belongs to the transferred entry.
fn SourceDocument::block_range(
  self : SourceDocument,
  indices : Array[Int32],
) -> (Int32, Int32) raise {
  let span = self.span(indices)
  let line = self.line_start(span.key_start)
  let mut start = if self.chars[line:span.key_start].all(c => {
      c == ' ' || c == '\t'
    }) {
    line
  } else {
    span.key_start
  }
  let last = indices[indices.length() - 1]
  let lower = if last > 0 {
    self.span([..indices[:indices.length() - 1], last - 1]).entry_end
  } else if indices.length() > 1 {
    self.span(indices[:indices.length() - 1].to_owned()).value_start + 1
  } else {
    start
  }
  while start > lower {
    let mut previous_end = start
    if previous_end > 0 && self.chars[previous_end - 1] == '\n' {
      previous_end -= 1
    }
    if previous_end > 0 && self.chars[previous_end - 1] == '\r' {
      previous_end -= 1
    }
    let previous_start = self.line_start(previous_end)
    if previous_start < lower || previous_start == start {
      break
    }
    let text = String::from_array(
        self.chars[previous_start:previous_end].to_owned(),
      )
      .trim()
      .to_owned()
    if !text.has_prefix("//") {
      break
    }
    start = previous_start
  }
  let mut end = span.entry_end
  while end < self.chars.length() &&
        (self.chars[end] == ' ' || self.chars[end] == '\t') {
    end += 1
  }
  if end + 1 < self.chars.length() &&
    self.chars[end] == '/' &&
    self.chars[end + 1] == '/' {
    while end < self.chars.length() &&
          self.chars[end] != '\n' &&
          self.chars[end] != '\r' {
      end += 1
    }
  }
  if end < self.chars.length() &&
    (self.chars[end] == '\r' || self.chars[end] == '\n') {
    if self.chars[end] == '\r' && self.chars.get(end + 1) == Some('\n') {
      end += 2
    } else {
      end += 1
    }
  } else if end != self.chars.length() {
    end = span.entry_end
  }
  (start, end)
}

///|
/// Reindent only at line starts outside quoted values. Multiline string contents
/// stay byte-for-byte identical; embedded // inside strings is ordinary data.
fn SourceDocument::reindent_block(
  self : SourceDocument,
  text : String,
  old : String,
  indent : String,
) -> String {
  let chars = text.to_array()
  let old_chars = old.to_array()
  let output = StringBuilder()
  let mut i = 0
  let mut quoted = false
  let mut escaped = false
  let mut comment = false
  let mut line_start = true
  while i < chars.length() {
    if line_start && !quoted {
      let matches = i + old_chars.length() <= chars.length() &&
        chars[i:i + old_chars.length()].to_owned() == old_chars
      if matches {
        i += old_chars.length()
      }
      output.write_string(indent)
    }
    if i >= chars.length() {
      break
    }
    let c = chars[i]
    output.write_char(c)
    if quoted {
      if escaped {
        escaped = false
      } else if c == '\\' && self.options.escape_sequences {
        escaped = true
      } else if c == '"' {
        quoted = false
      }
    } else if !comment {
      if c == '"' {
        quoted = true
      } else if c == '/' && chars.get(i + 1) == Some('/') {
        comment = true
      }
    }
    line_start = c == '\n' || (c == '\r' && chars.get(i + 1) != Some('\n'))
    if line_start {
      comment = false
    }
    i += 1
  }
  output.to_string()
}

///|
pub fn SourceDocument::transfer(
  self : SourceDocument,
  from : Array[Selector],
  to : Array[Selector],
  index : Int32,
  copy~ : Bool = false,
) -> SourceDocument raise {
  let expected = self.doc.transfer(from, to, index, copy~)
  let source = self.doc.indices(from)
  let target = self.doc.indices(to)
  if !copy &&
    source[:source.length() - 1].to_owned() == target &&
    (
      index == source[source.length() - 1] ||
      index == source[source.length() - 1] + 1
    ) {
    return self
  }
  let (start, end) = self.block_range(source)
  let children = self.doc.lookup_at(to).as_object().unwrap()
  let point = if index < children.length() {
    self.block_range([..target, index]).0
  } else if target.is_empty() {
    self.chars.length()
  } else {
    let closing = self.span(target).value_end - 1
    let line = self.line_start(closing)
    if self.chars[line:closing].all(c => c == ' ' || c == '\t') {
      line
    } else {
      closing
    }
  }
  let indent = if index < children.length() {
    self.line_indent(self.span([..target, index]).key_start)
  } else if target.is_empty() {
    ""
  } else {
    self.line_indent(self.span(target).key_start) + self.indent_unit()
  }
  let raw = String::from_array(self.chars[start:end].to_owned())
  let source_indent = self.line_indent(self.span(source).key_start)
  let mut inserted = self.reindent_block(
    raw,
    if start == self.span(source).key_start {
      ""
    } else {
      source_indent
    },
    indent,
  )
  if point > 0 && self.chars[point - 1] != '\n' && self.chars[point - 1] != '\r' {
    inserted = self.newline() + inserted
  }
  if !inserted.has_suffix("\n") && !inserted.has_suffix("\r") {
    inserted += self.newline()
  }
  let patches : Array[TextPatch] = [
    { start: point, end: point, text: inserted, },
  ]
  if !copy {
    patches.push({ start, end, text: "", })
  }
  self.patched(patches, expected)
}

///|
pub fn SourceDocument::transfer_json(
  self : SourceDocument,
  json : Json,
) -> SourceDocument raise {
  guard json is Object(fields) &&
    fields.get("from") is Some(from) &&
    fields.get("to") is Some(to) &&
    fields.get("index") is Some(Number(n, ..)) &&
    n >= 0 &&
    n <= 2147483647.0 &&
    n == n.to_int().to_double() else {
    raise InvalidEdit("Transfer requires from, to and index")
  }
  let copy = match fields.get("copy") {
    None => false
    Some(True) => true
    Some(False) => false
    _ => raise InvalidEdit("copy must be boolean")
  }
  if fields.length() != (if fields.contains("copy") { 4 } else { 3 }) {
    raise InvalidEdit("Unexpected transfer fields")
  }
  let paths = changes_from_json(
    Json::array([
      Json::object({ "path": from, "op": Json::string("remove") }),
      Json::object({ "path": to, "op": Json::string("remove") }),
    ]),
  )
  self.transfer(paths[0].path, paths[1].path, n.to_int(), copy~)
}
