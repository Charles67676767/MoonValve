///|
test "workspace rename updates active and inactive incoming references and rebases moved outgoing paths" {
  let files : Map[String, String] = {
    "main.vdf": "#include cfg/source.vdf\n#include cfg/source.vdf [$LINUX]\nroot { local yes }",
    "cfg/source.vdf": "// keep\n#base ../shared/default.vdf\nroot { owned yes }",
    "shared/default.vdf": "root { inherited yes }",
  }
  let workspace = @moonvalve.new_workspace(files)
  let renamed = workspace.rename_file("cfg/source.vdf", "new/deeper/moved.vdf")
  let result = renamed.files()
  assert_true(!result.contains("cfg/source.vdf"))
  assert_eq(
    result.get("main.vdf").unwrap(),
    "#include new/deeper/moved.vdf\n#include new/deeper/moved.vdf [$LINUX]\nroot { local yes }",
  )
  assert_eq(
    result.get("new/deeper/moved.vdf").unwrap(),
    "// keep\n#base ../../shared/default.vdf\nroot { owned yes }",
  )
  let options = {
    ..@moonvalve.ParseOptions::default(),
    conditions: Some(["WIN32"]),
  }
  assert_eq(
    @moonvalve.load_resolved("main.vdf", p => files.get(p).unwrap(), options~),
    @moonvalve.load_resolved("main.vdf", p => result.get(p).unwrap(), options~),
  )
  assert_eq(workspace.files(), files)
}

///|
test "workspace copies add remove and failed plans preserve original snapshot" {
  let workspace = @moonvalve.new_workspace({
    "main": "#base cfg/base root own",
    "cfg/base": "root defaults",
  })
  let copied = workspace.copy_file("main", "new/copy").files()
  assert_eq(copied.get("new/copy"), Some("#base ../cfg/base root own"))
  let added = workspace.add_file("unused", "root yes")
  assert_eq(added.remove_file("unused").files(), workspace.files())
  try workspace.remove_file("cfg/base") catch {
    @moonvalve.InvalidReference(_) => ()
    error => fail(error.to_string())
  } noraise {
    _ => fail("Expected incoming-reference refusal")
  }
  try workspace.rename_file("main", "cfg/base") catch {
    @moonvalve.InvalidReference(_) => ()
    error => fail(error.to_string())
  } noraise {
    _ => fail("Expected collision")
  }
  try workspace.add_file("../outside", "x y") catch {
    @moonvalve.InvalidReference(_) => ()
    error => fail(error.to_string())
  } noraise {
    _ => fail("Expected unsafe path")
  }
  let plan = @json.parse(
    "[{\"op\":\"add\",\"name\":\"extra\",\"text\":\"x y\"},{\"op\":\"rename\",\"from\":\"missing\",\"to\":\"other\"}]",
  )
  try workspace.apply(plan) catch {
    _ => ()
  } noraise {
    _ => fail("Expected failed plan")
  }
  assert_true(!workspace.files().contains("extra"))
}
