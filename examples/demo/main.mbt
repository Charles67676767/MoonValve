///|
fn main {
  let input =
    #|"AppState"
    #|{
    #|  "appid" "480"
    #|  "name" "Moon Harbor"
    #|  "installdir" "Moon Harbor"
    #|  "SizeOnDisk" "1048576"
    #|}
  try {
    let document = @valve.parse(input)
    let app = @valve.read_app_manifest(document)
    println("\{app.app_id}: \{app.name} (\{app.install_dir})")
    println(@valve.stringify(document))
  } catch {
    error => println(error.to_string())
  }
}
