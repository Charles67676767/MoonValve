///|
test "resource DATA decode bounds and exact binary edits preserve unrelated IEEE bits" {
  let document : @moonvalve.KV3BinaryDocument = {
    version: 5,
    compression: 2,
    format_id: @moonvalve.generic_kv3_header().format_id,
    root: @moonvalve.BObject([
      ("keep", @moonvalve.BNumber(19, 2143289345UL)),
      ("change", @moonvalve.BString("old")),
      (
        "arr",
        @moonvalve.BArray([@moonvalve.BBool(true), @moonvalve.BBool(false)]),
      ),
    ]),
  }
  let edited = document.edit_query(
    "/change",
    @moonvalve.KV3SetValue(@moonvalve.KV3String("new")),
  )
  assert_eq(
    edited.select("/keep")[0].value,
    @moonvalve.BNumber(19, 2143289345UL),
  )
  let resource = @moonvalve.encode_kv3_resource(edited, compression=2)
  let container = @moonvalve.read_resource_container(resource)
  assert_eq(container.data().root, edited.root)
  assert_eq(container.external_references().length(), 0)
  assert_eq(
    edited
    .edit_query("/arr/*?==false", @moonvalve.KV3RemoveMatches)
    .select("/arr/*")
    .length(),
    1,
  )
  assert_true(
    try {
      edited.edit_query("/change", @moonvalve.KV3RenameMatches("keep"))
      |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      @moonvalve.read_resource_container(
        resource[:resource.length() - 1].to_owned(),
      )
      |> ignore
      false
    } catch {
      _ => true
    },
  )
}
