///|
pub(all) struct LocalizationToken {
  name : String
  text : String
} derive(Eq, Debug)

///|
pub(all) struct Localization {
  language : String
  tokens : Array[LocalizationToken]
  encoding : String
} derive(Eq, Debug)

///|
pub(all) struct LocalizationIssue {
  token : String
  code : String
  message : String
} derive(Eq, Debug)

///|
pub extend LocalizationToken with Eq::{equal, not_equal}

///|
pub extend LocalizationToken with @debug.Debug::{to_repr}

///|
pub extend Localization with Eq::{equal, not_equal}

///|
pub extend Localization with @debug.Debug::{to_repr}

///|
pub extend LocalizationIssue with Eq::{equal, not_equal}

///|
pub extend LocalizationIssue with @debug.Debug::{to_repr}

///|
fn localization_validate(document : Localization) -> Unit raise {
  if document.tokens.length() > 100000 ||
    document.language.is_empty() ||
    document.language.char_length() > 1048576 ||
    document.language.to_array().any(c => c.to_int() < 32 || c.to_int() == 127) {
    raise InvalidDocument("Invalid localization language or token budget")
  }
  let names : Map[String, Bool] = Map([])
  let mut chars = document.language.char_length()
  for token in document.tokens {
    if token.name.is_empty() || names.contains(token.name.to_lower()) {
      raise InvalidDocument("Duplicate or empty localization token")
    }
    names[token.name.to_lower()] = true
    chars += token.name.char_length() + token.text.char_length()
    if chars > 8388608 ||
      token.name.contains("\u0000") ||
      token.text.contains("\u0000") {
      raise InvalidDocument("Localization exceeds input budget or contains NUL")
    }
  }
}

///|
/// BOM determines UTF-16 endianness. UTF-8 without a BOM remains valid; malformed
/// Unicode is rejected, never replaced with lossy text.
pub fn read_localization(bytes : Bytes) -> Localization raise {
  if bytes.length() > 16777216 {
    raise InvalidDocument("Localization exceeds byte budget")
  }
  let encoding = if bytes.length() >= 2 && bytes[:2].to_owned() == b"\xff\xfe" {
    "utf16le"
  } else if bytes.length() >= 2 && bytes[:2].to_owned() == b"\xfe\xff" {
    "utf16be"
  } else if bytes.length() >= 3 && bytes[:3].to_owned() == b"\xef\xbb\xbf" {
    "utf8-bom"
  } else {
    "utf8"
  }
  let text = match encoding {
    "utf16le" =>
      @utf16.decode(bytes[2:], ignore_bom=false, endianness=@utf16.Little)
    "utf16be" =>
      @utf16.decode(bytes[2:], ignore_bom=false, endianness=@utf16.Big)
    "utf8-bom" => @utf8.decode(bytes[3:], ignore_bom=false)
    _ => @utf8.decode(bytes[:], ignore_bom=false)
  }
  let document = parse(text)
  guard document.entries.length() == 1 &&
    document.entries[0].key.to_lower() == "lang" &&
    document.entries[0].value is Object(entries) &&
    game_child(entries, "Language") is Some(Text(language)) &&
    game_child(entries, "Tokens") is Some(Object(values)) else {
    raise InvalidDocument(
      "Expected lang/Language/Tokens localization structure",
    )
  }
  let tokens = values.map(e => {
    guard e.value is Text(text) else {
      raise InvalidDocument("Localization tokens must be strings")
    }
    LocalizationToken::{ name: e.key, text, }
  })
  let result = Localization::{ language, tokens, encoding, }
  localization_validate(result)
  result
}

///|
pub fn Localization::write(
  self : Localization,
  encoding? : String = self.encoding,
) -> Bytes raise {
  localization_validate(self)
  let text = stringify({
    entries: [
      {
        key: "lang",
        value: Object([
          { key: "Language", value: Text(self.language), },
          {
            key: "Tokens",
            value: Object(
              self.tokens.map(t => { key: t.name, value: Text(t.text), }),
            ),
          },
        ]),
      },
    ],
  })
  match encoding {
    "utf8" => @utf8.encode(text[:])
    "utf8-bom" => {
      let out = @buffer.Buffer()
      out.write_bytes(b"\xef\xbb\xbf"[:])
      out.write_bytes(@utf8.encode(text[:])[:])
      out.to_bytes()
    }
    "utf16le" => @utf16.encode(text[:], bom=true, endianness=@utf16.Little)
    "utf16be" => @utf16.encode(text[:], bom=true, endianness=@utf16.Big)
    _ => raise InvalidDocument("Expected utf8, utf8-bom, utf16le or utf16be")
  }
}

///|
fn localization_digit(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
/// Validate Valve indexed %s1/%d2, printf argument identities, or brace tokens.
/// Sorted identities retain multiplicity, so dropped/repeated parameters differ.
pub fn localization_placeholders(
  text : String,
  syntax? : String = "valve",
) -> Array[String] raise {
  if text.char_length() > 1048576 {
    raise InvalidDocument("Placeholder input exceeds token budget")
  }
  if !["valve", "printf", "brace"].contains(syntax) {
    raise InvalidDocument("Unknown placeholder syntax")
  }
  let chars = text.to_array()
  let output : Array[String] = []
  let mut i = 0
  let mut sequential = 1
  let mut positional = false
  let mut ordinary = false
  while i < chars.length() {
    let c = chars[i]
    i += 1
    if syntax == "brace" {
      if c == '{' {
        if chars.get(i) == Some('{') {
          i += 1
          continue
        }
        let start = i
        while i < chars.length() && chars[i] != '}' {
          if chars[i] == '{' {
            raise InvalidDocument("Nested brace placeholder")
          }
          i += 1
        }
        if i == chars.length() || i == start {
          raise InvalidDocument("Unclosed or empty brace placeholder")
        }
        let key = String::from_array(chars[start:i].to_owned())
        if chars[start:i].any(ch => {
            !((ch >= 'a' && ch <= 'z') ||
            (ch >= 'A' && ch <= 'Z') ||
            localization_digit(ch) ||
            ['_', ':', '-', '.'].contains(ch))
          }) {
          raise InvalidDocument("Invalid brace placeholder")
        }
        output.push(key)
        i += 1
      } else if c == '}' {
        if chars.get(i) != Some('}') {
          raise InvalidDocument("Unmatched closing brace")
        }
        i += 1
      }
      continue
    }
    if c != '%' {
      continue
    }
    if chars.get(i) == Some('%') {
      i += 1
      continue
    }
    if syntax == "valve" {
      if chars.get(i).map(ch => ['s', 'd', 'i', 'f'].contains(ch)) != Some(true) {
        continue
      }
      let kind = chars[i]
      i += 1
      let start = i
      while i < chars.length() && localization_digit(chars[i]) {
        i += 1
      }
      if i == start || chars[start] == '0' {
        raise InvalidDocument("Valve placeholder requires a positive index")
      }
      output.push(
        kind.to_string() + ":" + String::from_array(chars[start:i].to_owned()),
      )
      continue
    }
    let start = i
    while i < chars.length() && localization_digit(chars[i]) {
      i += 1
    }
    let argument = if i > start && chars.get(i) == Some('$') {
      positional = true
      i += 1
      let n = @strconv.parse_int(
        String::from_array(chars[start:i - 1].to_owned())[:],
      )
      if n < 1 {
        raise InvalidDocument("Printf argument index must be positive")
      }
      n
    } else {
      i = start
      ordinary = true
      let n = sequential
      sequential += 1
      n
    }
    while i < chars.length() &&
          ['-', '+', ' ', '#', '0', '\''].contains(chars[i]) {
      i += 1
    }
    if chars.get(i) == Some('*') {
      raise InvalidDocument(
        "Dynamic printf widths require an explicit format adapter",
      )
    }
    while i < chars.length() && localization_digit(chars[i]) {
      i += 1
    }
    if chars.get(i) == Some('.') {
      i += 1
      if chars.get(i) == Some('*') {
        raise InvalidDocument("Dynamic printf precision is unsupported")
      }
      while i < chars.length() && localization_digit(chars[i]) {
        i += 1
      }
    }
    let length_start = i
    while i < chars.length() &&
          ['h', 'l', 'j', 'z', 't', 'L'].contains(chars[i]) {
      i += 1
    }
    let length = String::from_array(chars[length_start:i].to_owned())
    if i == chars.length() ||
      ![
        'd', 'i', 'u', 'o', 'x', 'X', 'f', 'F', 'e', 'E', 'g', 'G', 'a', 'A', 'c',
        's', 'p',
      ].contains(chars[i]) {
      raise InvalidDocument("Unsupported or incomplete printf placeholder")
    }
    let kind = if ['d', 'i'].contains(chars[i]) {
      "d"
    } else if ['u', 'o', 'x', 'X'].contains(chars[i]) {
      "u"
    } else if ['f', 'F', 'e', 'E', 'g', 'G', 'a', 'A'].contains(chars[i]) {
      "f"
    } else {
      chars[i].to_string()
    }
    output.push(argument.to_string() + ":" + length + kind)
    i += 1
  }
  if positional && ordinary {
    raise InvalidDocument("Mixed positional and sequential printf placeholders")
  }
  output.sort_by((a, b) => a.lexical_compare(b))
  output
}

///|
pub fn Localization::validate_translation(
  self : Localization,
  translated : Localization,
  syntax? : String = "valve",
) -> Array[LocalizationIssue] raise {
  localization_validate(self)
  localization_validate(translated)
  let targets : Map[String, String] = Map([])
  for token in translated.tokens {
    targets[token.name.to_lower()] = token.text
  }
  let output : Array[LocalizationIssue] = []
  let names : Map[String, Bool] = Map([])
  for token in self.tokens {
    let key = token.name.to_lower()
    names[key] = true
    if targets.get(key) is Some(text) {
      try {
        if localization_placeholders(token.text, syntax~) !=
          localization_placeholders(text, syntax~) {
          output.push({
            token: token.name,
            code: "placeholder_mismatch",
            message: "Translation changes placeholder identities or multiplicity",
          })
        }
      } catch {
        _ =>
          output.push({
            token: token.name,
            code: "invalid_placeholder",
            message: "Source or translation has an invalid placeholder",
          })
      }
    } else {
      output.push({
        token: token.name,
        code: "missing_token",
        message: "Translation is missing this token",
      })
    }
  }
  for token in translated.tokens {
    if !names.contains(token.name.to_lower()) {
      output.push({
        token: token.name,
        code: "extra_token",
        message: "Translation token is absent from the source catalog",
      })
    }
  }
  output
}
