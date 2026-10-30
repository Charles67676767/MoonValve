///|
pub suberror ConditionError {
  InvalidCondition(String)
} derive(Debug)

///|
pub extend ConditionError with @debug.Debug::{to_repr}

///|
priv struct ConditionParser {
  chars : Array[Char]
  symbols : Array[String]
  mut pos : Int32
}

///|
/// Evaluate $NAME, !, &&, || and parentheses. Symbols are explicit and ASCII
/// case-insensitive; unknown symbols are false. No host platform is inferred.
pub fn evaluate_condition(
  expression : String,
  symbols : Array[String],
) -> Bool raise ConditionError {
  if expression.char_length() > 4096 {
    raise InvalidCondition("Expression exceeds 4096 characters")
  }
  let p = ConditionParser::{ chars: expression.to_array(), symbols, pos: 0, }
  let value = p.read_or(0)
  p.space()
  if p.pos != p.chars.length() {
    raise InvalidCondition("Unexpected conditional token")
  }
  value
}

///|
fn ConditionParser::space(self : ConditionParser) -> Unit {
  while self.chars.get(self.pos) is Some(c) && is_space(c) {
    self.pos += 1
  }
}

///|
fn ConditionParser::take(self : ConditionParser, c : Char) -> Bool {
  self.space()
  if self.chars.get(self.pos) == Some(c) {
    self.pos += 1
    true
  } else {
    false
  }
}

///|
fn ConditionParser::read_or(
  self : ConditionParser,
  depth : Int32,
) -> Bool raise ConditionError {
  let mut value = self.read_and(depth)
  while self.take('|') {
    if self.chars.get(self.pos) != Some('|') {
      raise InvalidCondition("Expected ||")
    }
    self.pos += 1
    let rhs = self.read_and(depth)
    value = value || rhs
  }
  value
}

///|
fn ConditionParser::read_and(
  self : ConditionParser,
  depth : Int32,
) -> Bool raise ConditionError {
  let mut value = self.read_atom(depth)
  while self.take('&') {
    if self.chars.get(self.pos) != Some('&') {
      raise InvalidCondition("Expected &&")
    }
    self.pos += 1
    let rhs = self.read_atom(depth)
    value = value && rhs
  }
  value
}

///|
fn ConditionParser::read_atom(
  self : ConditionParser,
  depth : Int32,
) -> Bool raise ConditionError {
  if depth > 64 {
    raise InvalidCondition("Conditional nesting exceeds 64")
  }
  if self.take('!') {
    return !self.read_atom(depth + 1)
  }
  if self.take('(') {
    let value = self.read_or(depth + 1)
    if !self.take(')') {
      raise InvalidCondition("Missing closing parenthesis")
    }
    return value
  }
  if !self.take('$') {
    raise InvalidCondition("Expected $NAME")
  }
  let name = StringBuilder()
  while self.chars.get(self.pos) is Some(c) &&
        (
          (c >= 'a' && c <= 'z') ||
          (c >= 'A' && c <= 'Z') ||
          (c >= '0' && c <= '9') ||
          c == '_'
        ) {
    name.write_char(c)
    self.pos += 1
  }
  let text = name.to_string()
  if text.is_empty() {
    raise InvalidCondition("Empty symbol")
  }
  self.symbols.any(s => {
    s.equal_ignore_ascii_case(text) || s.equal_ignore_ascii_case("$" + text)
  })
}
