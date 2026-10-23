///|
fn stream_output(text : String) -> Unit raise {
  host_output(text)
  host_output_check()
}

///|
fn run_stream(command : String, args : Array[String]) -> Unit raise {
  if args.length() < 4 {
    raise InvalidArgument("Streaming requires a filename or -")
  }
  let keys : Array[String] = []
  let mut literal = false
  let mut limit = 67108864
  let mut i = 4
  let mut positional = false
  while i < args.length() {
    if positional {
      keys.push(args[i])
    } else {
      match args[i] {
        "--" => positional = true
        "--literal" => literal = true
        "--max-bytes" => {
          i += 1
          if i >= args.length() {
            raise InvalidArgument("--max-bytes requires a value")
          }
          limit = @strconv.parse_int(args[i]) catch {
            _ => raise InvalidArgument("Invalid byte budget")
          }
          if limit < 1 || limit > 1073741824 {
            raise InvalidArgument("Byte budget must be 1..1073741824")
          }
        }
        other => {
          if other.has_prefix("--") {
            raise InvalidArgument("Unknown stream option: " + other)
          }
          keys.push(other)
        }
      }
    }
    i += 1
  }
  if (command == "stream-query" && keys.is_empty()) ||
    (command != "stream-query" && !keys.is_empty()) {
    raise InvalidArgument(
      "Only stream-query accepts a nonempty scalar key path",
    )
  }
  let parents : Array[String] = []
  let counts : Array[Int] = [0]
  let path : Array[Json] = []
  let writer = @valve.new_stream_writer(stream_output)
  if command == "stream-csv" {
    stream_output("path,value\r\n")
  }
  let parser = @valve.new_stream_parser(
    event => {
      if command == "stream-format" {
        writer.write(event)
        return true
      }
      let mut row : Json = Json::null()
      match event {
        @valve.Pair(key, _) | @valve.BeginObject(key) => {
          let index = counts[counts.length() - 1]
          counts[counts.length() - 1] = index + 1
          let selector = Json::object({
            "key": Json::string(key),
            "index": Json::number(index.to_double()),
          })
          let current = path.map(p => p)
          current.push(selector)
          match event {
            @valve.Pair(_, value) => {
              row = Json::object({
                "event": Json::string("pair"),
                "path": Json::array(current),
                "value": Json::string(value),
              })
              if command == "stream-query" && [..parents, key] == keys {
                stream_output(row.stringify() + "\n")
              }
              if command == "stream-csv" {
                let location = Json::array(current)
                  .stringify()
                  .replace_all(old="\"", new="\"\"")
                let cell = value.replace_all(old="\"", new="\"\"")
                stream_output("\"" + location + "\",\"" + cell + "\"\r\n")
              }
            }
            _ => {
              row = Json::object({
                "event": Json::string("begin"),
                "path": Json::array(current),
              })
              parents.push(key)
              path.push(selector)
              counts.push(0)
            }
          }
        }
        @valve.EndObject => {
          row = Json::object({
            "event": Json::string("end"),
            "path": Json::array(path.map(p => p)),
          })
          parents.pop() |> ignore
          path.pop() |> ignore
          counts.pop() |> ignore
        }
        @valve.Condition(key, expression) =>
          row = Json::object({
            "event": Json::string("condition"),
            "key": Json::string(key),
            "expression": Json::string(expression),
          })
      }
      if command == "stream-json" {
        stream_output(row.stringify() + "\n")
      }
      true
    },
    options={
      ..@valve.ParseOptions::default(),
      escape_sequences: !literal,
      max_input_chars: limit,
      max_entries: 10000000,
    },
  )
  let handle = host_stream_open(args[3])
  defer host_stream_close(handle)
  let mut bytes = 0
  while true {
    let chunk = host_stream_chunk(handle)
    if chunk.is_empty() {
      break
    }
    if chunk.length() > limit - bytes {
      raise InvalidArgument("Streaming input exceeds byte budget")
    }
    bytes += chunk.length()
    parser.feed_bytes(chunk)
  }
  parser.finish()
  if command == "stream-format" {
    writer.finish()
  }
}
