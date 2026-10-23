///|
test "stream events are identical at every text boundary and single-byte UTF8 boundary" {
  let input = "\uFEFF// comment\r\nroot { key \"中文😀\\nvalue\" key two [$WIN32] nested { url http://example } }"
  let expected : Array[@moonvalve.StreamEvent] = [
    @moonvalve.BeginObject("root"),
    @moonvalve.Pair("key", "中文😀\nvalue"),
    @moonvalve.Pair("key", "two"),
    @moonvalve.Condition("key", "$WIN32"),
    @moonvalve.BeginObject("nested"),
    @moonvalve.Pair("url", "http://example"),
    @moonvalve.EndObject,
    @moonvalve.EndObject,
  ]
  let chars = input.to_array()
  for split in 0..<(chars.length() + 1) {
    let events : Array[@moonvalve.StreamEvent] = []
    let parser = @moonvalve.new_stream_parser(event => {
      events.push(event)
      true
    })
    parser.feed(String::from_array(chars[:split].to_owned()))
    parser.feed(String::from_array(chars[split:].to_owned()))
    parser.finish()
    assert_eq(events, expected)
  }
  let events : Array[@moonvalve.StreamEvent] = []
  let parser = @moonvalve.new_stream_parser(event => {
    events.push(event)
    true
  })
  for byte in @utf8.encode(input[:]) {
    parser.feed_bytes(Bytes::from_array([byte]))
  }
  parser.finish()
  assert_eq(events, expected)
}

///|
test "stream skip validates discarded objects without building a tree" {
  let events : Array[@moonvalve.StreamEvent] = []
  let parser = @moonvalve.new_stream_parser(event => {
    events.push(event)
    event != @moonvalve.BeginObject("skip")
  })
  parser.feed("skip {")
  for i in 0..<10000 {
    parser.feed("k \{i} ")
  }
  parser.feed("nested { a b } } tail yes")
  parser.finish()
  assert_eq(events, [
    @moonvalve.BeginObject("skip"),
    @moonvalve.EndObject,
    @moonvalve.Pair("tail", "yes"),
  ])
  assert_eq(parser.entries_seen(), 10004)
}

///|
test "stream rejects incomplete syntax invalid UTF8 and exceeded budgets" {
  for text in ["k", "r { k v", "k \"x\\", "k v [$X", "}", "k = = v"] {
    let parser = @moonvalve.new_stream_parser(_ => true)
    try {
      parser.feed(text)
      parser.finish()
    } catch {
      _ => ()
    } noraise {
      _ => fail("Expected malformed stream")
    }
  }
  let parser = @moonvalve.new_stream_parser(_ => true)
  parser.feed_bytes(b"k \"")
  parser.feed_bytes(b"\xf0\x9f")
  try parser.finish() catch {
    _ => ()
  } noraise {
    _ => fail("Expected incomplete UTF8")
  }
  let limited = @moonvalve.new_stream_parser(_ => false, options={
    ..@moonvalve.ParseOptions::default(),
    max_entries: 1,
  })
  try limited.feed("skip { child value }") catch {
    _ => ()
  } noraise {
    _ => fail("Skipped entries must count")
  }
}
