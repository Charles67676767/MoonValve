///|
fn demonstrate() -> Unit raise {
  let pairs : Ref[Int32] = { val: 0, }
  let parser = @valve.new_stream_parser(
    event => {
      if event is @valve.Pair(_, _) {
        pairs.val += 1
      }
      true
    },
    options={
      ..@valve.ParseOptions::default(),
      max_entries: 1000001,
      max_input_chars: 50000000,
    },
  )
  parser.feed("root {\n")
  for i in 0..<1000000 {
    parser.feed("key \{i}\n")
  }
  parser.feed("}\n")
  parser.finish()
  assert_eq(pairs.val, 1000000)
  println(
    "\{pairs.val} pairs from \{parser.characters_seen()} characters without a document tree",
  )
}

///|
fn main {
  demonstrate() catch {
    error => println(error.to_string())
  }
}
