///|
pub(all) struct KV3BinaryLocatedValue {
  path : Array[String]
  value : KV3BinaryValue
} derive(Eq, Debug)

///|
pub extend KV3BinaryLocatedValue with Eq::{equal, not_equal}

///|
pub extend KV3BinaryLocatedValue with @debug.Debug::{to_repr}

///|
fn KV3BinaryValue::at(
  self : KV3BinaryValue,
  indices : Array[Int],
) -> KV3BinaryValue raise {
  let mut value = self
  for i in indices {
    if value is BFlag(_, inner) {
      value = inner
    }
    value = match value {
      BObject(entries) => entries[i].1
      BArray(values) => values[i]
      _ => raise InvalidQuery("Invalid binary KV3 path")
    }
  }
  value
}

///|
pub fn KV3BinaryDocument::select(
  self : KV3BinaryDocument,
  expression : String,
) -> Array[KV3BinaryLocatedValue] raise {
  compile_kv3_query(expression)
  .matches(self.document())
  .map(row => { path: row.path, value: self.root.at(row.indices), })
}

///|
fn kv3_binary_patch(
  value : KV3BinaryValue,
  path : Array[Int],
  replacements : Map[String, KV3BinaryValue],
  removals : Map[String, Bool],
  renames : Map[String, String],
) -> KV3BinaryValue {
  if replacements.get(index_key(path)) is Some(new_value) {
    return new_value
  }
  match value {
    BFlag(flag, inner) =>
      BFlag(
        flag,
        kv3_binary_patch(inner, path, replacements, removals, renames),
      )
    BObject(entries) => {
      let output : Array[(String, KV3BinaryValue)] = []
      for i in 0..<entries.length() {
        let child = path + [i]
        let id = index_key(child)
        if removals.contains(id) {
          continue
        }
        let key = renames.get(id).unwrap_or(entries[i].0)
        output.push(
          (
            key,
            kv3_binary_patch(
              entries[i].1,
              child,
              replacements,
              removals,
              renames,
            ),
          ),
        )
      }
      BObject(output)
    }
    BArray(values) => {
      let output : Array[KV3BinaryValue] = []
      for i in 0..<values.length() {
        let child = path + [i]
        if removals.contains(index_key(child)) {
          continue
        }
        output.push(
          kv3_binary_patch(values[i], child, replacements, removals, renames),
        )
      }
      BArray(output)
    }
    _ => value
  }
}

///|
/// Snapshot query edits retain untouched storage widths and exact IEEE bits.
/// Replacements use the ordinary KV3 value model; ambiguous overlaps fail.
pub fn KV3BinaryDocument::edit_query(
  self : KV3BinaryDocument,
  expression : String,
  operation : KV3QueryEdit,
) -> KV3BinaryDocument raise {
  let rows = compile_kv3_query(expression).matches(self.document())
  let replacements : Map[String, KV3BinaryValue] = Map([])
  let removals : Map[String, Bool] = Map([])
  let renames : Map[String, String] = Map([])
  let selected : Map[String, Bool] = Map([])
  for row in rows {
    selected[index_key(row.indices)] = true
  }
  for row in rows {
    for i in 0..<row.indices.length() {
      if selected.contains(index_key(row.indices[:i].to_owned())) {
        raise InvalidQuery("Overlapping binary KV3 edits")
      }
    }
    let key = index_key(row.indices)
    match operation {
      KV3SetValue(value) =>
        replacements[key] = kv3_binary_from_document({
            header: None,
            root: value,
          }).root
      KV3ReplacePrefix(from, to) =>
        replacements[key] = kv3_binary_from_document({
            header: None,
            root: kv3_prefix_value(row.value, from, to),
          }).root
      KV3RemoveMatches => {
        if row.indices.is_empty() {
          raise InvalidQuery("Cannot remove root")
        }
        removals[key] = true
      }
      KV3RenameMatches(name) => {
        if row.indices.is_empty() {
          raise InvalidQuery("Cannot rename root")
        }
        let parent = self.root.at(
          row.indices[:row.indices.length() - 1].to_owned(),
        )
        let parent = if parent is BFlag(_, inner) { inner } else { parent }
        if !(parent is BObject(_)) {
          raise InvalidQuery("Cannot rename an array element")
        }
        renames[key] = name
      }
    }
  }
  let result = {
    ..self,
    root: kv3_binary_patch(self.root, [], replacements, removals, renames),
  }
  result.document() |> ignore
  result
}
