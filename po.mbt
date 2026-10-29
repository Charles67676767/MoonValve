///|
pub(all) struct POEntry {
  context : String?
  id : String
  plural : String?
  translations : Array[String]
  comments : Array[String]
  flags : Array[String]
  obsolete : Bool
} derive(Eq, Debug)

///|
pub(all) struct POCatalog {
  entries : Array[POEntry]
  trailing_comments : Array[String]
} derive(Eq, Debug)

///|
pub extend POEntry with Eq::{equal, not_equal}

///|
pub extend POEntry with @debug.Debug::{to_repr}

///|
pub extend POCatalog with Eq::{equal, not_equal}

///|
pub extend POCatalog with @debug.Debug::{to_repr}

///|
fn po_unquote(text : String) -> String raise {
  let chars = text.trim().to_owned().to_array()
  if chars.length() < 2 || chars[0] != '"' || chars[chars.length() - 1] != '"' {
    raise InvalidDocument("Expected a quoted PO string")
  }
  let output = StringBuilder()
  let mut i = 1
  while i < chars.length() - 1 {
    let c = chars[i]
    i += 1
    if c == '"' || c.to_int() < 32 {
      raise InvalidDocument("Unescaped control or quote in PO string")
    }
    if c != '\\' {
      output.write_char(c)
      continue
    }
    if i >= chars.length() - 1 {
      raise InvalidDocument("Incomplete PO escape")
    }
    let escape = chars[i]
    i += 1
    let value = match escape {
      'n' => '\n'
      'r' => '\r'
      't' => '\t'
      'a' => '\u0007'
      'b' => '\u0008'
      'f' => '\u000c'
      'v' => '\u000b'
      '\\' => '\\'
      '"' => '"'
      '0'..='7' => {
        let mut n = escape.to_int() - 48
        let mut count = 1
        while count < 3 &&
              i < chars.length() - 1 &&
              chars[i] >= '0' &&
              chars[i] <= '7' {
          n = n * 8 + chars[i].to_int() - 48
          i += 1
          count += 1
        }
        if n == 0 || n > 127 {
          raise InvalidDocument(
            "PO octal escapes must encode non-NUL ASCII; use Unicode text for other characters",
          )
        }
        n.to_char().unwrap()
      }
      _ => raise InvalidDocument("Unsupported PO escape")
    }
    output.write_char(value)
  }
  output.to_string()
}

///|
fn po_quote(text : String) -> String raise {
  if text.contains("\u0000") {
    raise InvalidDocument("NUL in PO string")
  }
  let output = StringBuilder()
  output.write_char('"')
  for c in text {
    match c {
      '"' => output.write_string("\\\"")
      '\\' => output.write_string("\\\\")
      '\n' => output.write_string("\\n")
      '\r' => output.write_string("\\r")
      '\t' => output.write_string("\\t")
      _ =>
        if c.to_int() < 32 || c.to_int() == 127 {
          let n = c.to_int()
          output.write_char('\\')
          output.write_char((48 + n / 64).to_char().unwrap())
          output.write_char((48 + n / 8 % 8).to_char().unwrap())
          output.write_char((48 + n % 8).to_char().unwrap())
        } else {
          output.write_char(c)
        }
    }
  }
  output.write_char('"')
  output.to_string()
}

///|
priv struct POBuilder {
  fields : Map[String, String]
  comments : Array[String]
  flags : Array[String]
  mut active : String?
  mut obsolete : Bool?
}

///|
fn po_builder() -> POBuilder {
  { fields: Map([]), comments: [], flags: [], active: None, obsolete: None, }
}

///|
fn POBuilder::finish(self : POBuilder) -> POEntry raise {
  guard self.fields.get("msgid") is Some(id) else {
    raise InvalidDocument("PO entry has no msgid")
  }
  let plural = self.fields.get("msgid_plural")
  let translations : Array[String] = []
  if plural is None {
    guard self.fields.get("msgstr") is Some(text) &&
      !self.fields.contains("msgstr[0]") else {
      raise InvalidDocument("PO singular entry needs one msgstr")
    }
    translations.push(text)
  } else {
    if self.fields.contains("msgstr") {
      raise InvalidDocument("PO plural entry requires indexed msgstr")
    }
    let mut i = 0
    while self.fields.get("msgstr[" + i.to_string() + "]") is Some(text) {
      translations.push(text)
      i += 1
    }
    if translations.is_empty() ||
      self.fields.length() !=
      translations.length() +
      2 +
      (if self.fields.contains("msgctxt") { 1 } else { 0 }) {
      raise InvalidDocument("PO plural indices must be contiguous from zero")
    }
  }
  {
    context: self.fields.get("msgctxt"),
    id,
    plural,
    translations,
    comments: self.comments.copy(),
    flags: self.flags.copy(),
    obsolete: self.obsolete.unwrap_or(false),
  }
}

///|
pub fn parse_po(text : String) -> POCatalog raise {
  if text.char_length() > 8388608 || text.contains("\u0000") {
    raise InvalidDocument("PO input exceeds budget or contains NUL")
  }
  let entries : Array[POEntry] = []
  let mut builder = po_builder()
  for raw in text.split("\n") {
    let line = raw.trim().to_owned()
    if line.is_empty() {
      if !builder.fields.is_empty() {
        entries.push(builder.finish())
        builder = po_builder()
      }
      continue
    }
    let obsolete = line.has_prefix("#~")
    let line = if obsolete { line[2:].trim_start().to_owned() } else { line }
    if line.has_prefix("#") {
      if builder.active.map(key => key.has_prefix("msgstr")) == Some(true) {
        entries.push(builder.finish())
        builder = po_builder()
      }
      if line.has_prefix("#,") {
        for raw_flag in line[2:].split(",") {
          let flag = raw_flag.trim().to_owned()
          if !flag.is_empty() && !builder.flags.contains(flag) {
            builder.flags.push(flag)
          }
        }
      } else {
        builder.comments.push(line)
      }
      continue
    }
    if line.has_prefix("\"") {
      guard builder.active is Some(key) && builder.obsolete == Some(obsolete) else {
        raise InvalidDocument("PO continuation has no matching field")
      }
      builder.fields[key] = builder.fields[key] + po_unquote(line)
      continue
    }
    let mut recognized = false
    for prefix in ["msgctxt", "msgid_plural", "msgid", "msgstr"] {
      if !line.has_prefix(prefix) {
        continue
      }
      let mut key = prefix
      let mut offset = prefix.length()
      if prefix == "msgstr" && line[offset:].has_prefix("[") {
        guard line.find("]") is Some(end) else {
          raise InvalidDocument("Unclosed PO plural index")
        }
        let n = @strconv.parse_int(line[offset + 1:end])
        if n < 0 || n > 1023 || line[offset + 1:end].to_owned() != n.to_string() {
          raise InvalidDocument("Invalid PO plural index")
        }
        key = "msgstr[" + n.to_string() + "]"
        offset = end + 1
      }
      if offset >= line.length() || (line[offset] != 32 && line[offset] != 9) {
        continue
      }
      if (prefix == "msgctxt" || prefix == "msgid") &&
        builder.active.map(key => key.has_prefix("msgstr")) == Some(true) {
        entries.push(builder.finish())
        builder = po_builder()
      }
      if builder.fields.contains(key) ||
        (builder.obsolete is Some(previous) && previous != obsolete) {
        raise InvalidDocument("Duplicate or mixed obsolete PO field")
      }
      builder.fields[key] = po_unquote(line[offset:].to_owned())
      builder.active = Some(key)
      builder.obsolete = Some(obsolete)
      recognized = true
      break
    }
    if !recognized {
      raise InvalidDocument("Unsupported PO directive")
    }
    if entries.length() > 100000 {
      raise InvalidDocument("PO entry budget exceeded")
    }
  }
  if !builder.fields.is_empty() {
    entries.push(builder.finish())
    builder = po_builder()
  }
  let result = { entries, trailing_comments: builder.comments.copy(), }
  po_validate(result)
  result
}

///|
fn po_validate(catalog : POCatalog) -> Unit raise {
  if catalog.entries.length() > 100000 {
    raise InvalidDocument("PO entry budget exceeded")
  }
  let seen : Map[String, Bool] = Map([])
  let mut total = 0
  for entry in catalog.entries {
    let texts = [
        entry.id,
        entry.context.unwrap_or(""),
        entry.plural.unwrap_or(""),
      ] +
      entry.translations +
      entry.comments +
      entry.flags
    for text in texts {
      let size = text.char_length()
      if size > 8388608 - total || text.contains("\u0000") {
        raise InvalidDocument("PO model exceeds budget or contains NUL")
      }
      total += size
    }
    let key = Json::array([
      match entry.context {
        Some(s) => Json::string(s)
        None => Json::null()
      },
      Json::string(entry.id),
    ]).stringify()
    if !entry.obsolete && seen.contains(key) {
      raise InvalidDocument("Duplicate PO msgctxt/msgid")
    }
    if !entry.obsolete {
      seen[key] = true
    }
    if entry.translations.is_empty() ||
      (entry.plural is None && entry.translations.length() != 1) ||
      entry.translations.length() > 1024 {
      raise InvalidDocument("Invalid PO translations")
    }
    if entry.comments.any(s => {
        !s.has_prefix("#") ||
        s.has_prefix("#,") ||
        s.contains("\n") ||
        s.contains("\r")
      }) ||
      entry.flags.any(s => {
        s.is_empty() || s.contains(",") || s.contains("\n") || s.contains("\r")
      }) {
      raise InvalidDocument("Invalid PO comment or flag")
    }
  }
  for text in catalog.trailing_comments {
    let size = text.char_length()
    if size > 8388608 - total || text.contains("\u0000") {
      raise InvalidDocument("PO model exceeds budget or contains NUL")
    }
    total += size
  }
  if catalog.trailing_comments.any(s => {
      !s.has_prefix("#") || s.contains("\n") || s.contains("\r")
    }) {
    raise InvalidDocument("Invalid trailing PO comment")
  }
}

///|
pub fn POCatalog::stringify(self : POCatalog) -> String raise {
  po_validate(self)
  let output = StringBuilder()
  for entry in self.entries {
    let prefix = if entry.obsolete { "#~ " } else { "" }
    for comment in entry.comments {
      output.write_string(comment + "\n")
    }
    if !entry.flags.is_empty() {
      output.write_string("#, " + entry.flags.join(", ") + "\n")
    }
    if entry.context is Some(context) {
      output.write_string(prefix + "msgctxt " + po_quote(context) + "\n")
    }
    output.write_string(prefix + "msgid " + po_quote(entry.id) + "\n")
    if entry.plural is Some(plural) {
      output.write_string(prefix + "msgid_plural " + po_quote(plural) + "\n")
      for i in 0..<entry.translations.length() {
        output.write_string(
          prefix +
          "msgstr[" +
          i.to_string() +
          "] " +
          po_quote(entry.translations[i]) +
          "\n",
        )
      }
    } else {
      output.write_string(
        prefix + "msgstr " + po_quote(entry.translations[0]) + "\n",
      )
    }
    output.write_char('\n')
  }
  for comment in self.trailing_comments {
    output.write_string(comment + "\n")
  }
  let text = output.to_string()
  if text.char_length() > 8388608 {
    raise InvalidDocument("PO output exceeds budget")
  }
  text
}
