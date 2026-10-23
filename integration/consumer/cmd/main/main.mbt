///|
fn example() -> Unit raise {
  let doc = @valve.parse(
    "game { name MoonHarbor build 9007199254740993 tag singleplayer tag controller }",
  )
  let path : Array[@valve.Selector] = [
    { key: "game", occurrence: 0, },
    { key: "build", occurrence: 0, },
  ]
  assert_eq(doc.read_int64(path), 9007199254740993L)
  assert_eq(doc.lookup_all(["game", "tag"]).length(), 2)
  let updated = doc.apply([
    {
      path: [{ key: "game", occurrence: 0, }, { key: "tag", occurrence: 1, }],
      operation: @valve.Replace(@valve.Text("keyboard")),
    },
  ])
  println(@valve.stringify(updated))
}

///|
fn main {
  example() catch {
    error => println(error.to_string())
  }
}
