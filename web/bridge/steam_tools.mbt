///|
let browser_cache : Ref[@valve.SteamCache?] = { val: None, }

///|
fn cache_page(fields : Map[String, Json]) -> Json raise {
  guard browser_cache.val is Some(cache) else {
    raise Failure("Open a cache first")
  }
  let offset = match fields.get("offset") {
    None => 0
    Some(Number(n, ..)) if n >= 0 && n <= 1000000 && n == n.to_int().to_double() =>
      n.to_int()
    _ => raise Failure("Invalid page offset")
  }
  let query = match fields.get("query") {
    Some(String(s)) => s
    _ => ""
  }
  let page = cache.page(query~, offset~)
  Json::object({
    "format": Json::string(
      if cache.format() == @valve.AppInfo {
        "appinfo"
      } else {
        "packageinfo"
      },
    ),
    "version": Json::number(cache.version().to_double()),
    "total": Json::number(page.total.to_double()),
    "offset": Json::number(offset.to_double()),
    "records": Json::array(
      page.records.map(row => {
        Json::object({
          "id": Json::string(row.id.to_string()),
          "change_number": Json::string(row.change_number.to_string()),
          "token": Json::string(row.token.to_string()),
          "offset": Json::number(row.offset.to_double()),
          "length": Json::number(row.length.to_double()),
        })
      }),
    ),
  })
}

///|
#export_name("openCache")
pub fn open_cache(bytes : Bytes) -> String {
  browser_cache.val = None
  try {
    browser_cache.val = Some(
      @valve.open_steam_cache(bytes, max_bytes=134217728),
    )
    Json::object({ "ok": Json::boolean(true), "result": cache_page(Map([])) }).stringify()
  } catch {
    error =>
      Json::object({
        "ok": Json::boolean(false),
        "error": Json::object({
          "code": Json::string("cache_error"),
          "message": Json::string(error.to_string()),
        }),
      }).stringify()
  }
}

///|
fn cache_record(fields : Map[String, Json]) -> Json raise {
  guard browser_cache.val is Some(cache) else {
    raise Failure("Open a cache first")
  }
  let id = @strconv.parse_uint(field(fields, "id"))
  guard cache.read(id) is Some(data) else { raise Failure("Unknown cache ID") }
  Json::object({ "tree": @valve.binary_to_json(data) })
}

///|
fn shortcut_rows(file : @valve.ShortcutFile) -> Json raise {
  Json::array(
    file
    .shortcuts()
    .map(s => {
      Json::object({
        "index": Json::string(s.index),
        "app_id": Json::string(s.app_id.to_string()),
        "name": Json::string(s.name),
        "exe": Json::string(s.exe),
        "start_dir": Json::string(s.start_dir),
        "launch_options": Json::string(s.launch_options),
        "tags": Json::array(s.tags.map(Json::string)),
        "url": Json::string(s.url()),
      })
    }),
  )
}

///|
fn shortcut_text(
  fields : Map[String, Json],
  key : String,
  fallback : String,
) -> String raise {
  match fields.get(key) {
    None => fallback
    Some(String(s)) => s
    _ => raise Failure("Expected text: " + key)
  }
}

///|
fn shortcut_tools(action : String, fields : Map[String, Json]) -> Json raise {
  let mut file = if action == "shortcuts-new" {
    @valve.new_shortcut_file()
  } else {
    guard fields.get("tree") is Some(tree) else {
      raise Failure("Expected shortcut tree")
    }
    @valve.read_shortcut_file(@valve.binary_from_json(tree))
  }
  if action == "shortcuts-edit" {
    guard fields.get("changes") is Some(Array(changes)) &&
      changes.length() <= 10000 else {
      raise Failure("Expected bounded shortcut changes")
    }
    for change in changes {
      guard change is Object(row) else {
        raise Failure("Invalid shortcut change")
      }
      let op = field(row, "op")
      if op == "remove" {
        file = file.remove(field(row, "index"))
        continue
      }
      if op != "add" && op != "set" {
        raise Failure("Unknown shortcut operation")
      }
      guard row.get("fields") is Some(Object(definition)) else {
        raise Failure("Expected shortcut fields")
      }
      for key, _ in definition {
        if !["name", "exe", "start_dir", "launch_options", "tags"].contains(key) {
          raise Failure("Unknown shortcut field: " + key)
        }
      }
      let old = if op == "set" {
        let index = field(row, "index")
        let item = file.shortcuts().iter().find_first(s => s.index == index)
        guard item is Some(s) else { raise Failure("Unknown shortcut index") }
        s
      } else {
        @valve.SteamShortcut::{
          index: "",
          app_id: 0U,
          name: "",
          exe: "",
          start_dir: "",
          launch_options: "",
          tags: [],
        }
      }
      let name = shortcut_text(definition, "name", old.name)
      let exe = shortcut_text(definition, "exe", old.exe)
      let start_dir = shortcut_text(definition, "start_dir", old.start_dir)
      let launch_options = shortcut_text(
        definition,
        "launch_options",
        old.launch_options,
      )
      let tags = match definition.get("tags") {
        None => old.tags
        Some(Array(items)) =>
          items.map(item => {
            match item {
              String(s) => s
              _ => raise Failure("Tags must be strings")
            }
          })
        _ => raise Failure("Tags must be an array")
      }
      if name == "" || exe == "" {
        raise Failure("Shortcut name and executable are required")
      }
      file = if op == "set" {
        file.set({ ..old, name, exe, start_dir, launch_options, tags, })
      } else {
        file.add(name, exe, start_dir~, launch_options~, tags~)
      }
    }
  }
  let tree = @valve.binary_to_json(file.to_binary())
  // Validate that the final transaction can be written before offering a preview.
  @valve.encode_binary(file.to_binary()) |> ignore
  Json::object({ "tree": tree, "items": shortcut_rows(file) })
}
