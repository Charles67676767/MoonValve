///|
pub fn VPKArchive::to_json(self : VPKArchive) -> Json {
  Json::object({
    "version": Json::number(self.version.to_double()),
    "data_offset": Json::number(self.data_offset.to_double()),
    "embedded_size": match self.embedded_size() {
      Some(n) => Json::number(n.to_double())
      None => Json::null()
    },
    "entries": Json::array(
      self.entries.map(e => {
        Json::object({
          "path": Json::string(e.path),
          "archive": Json::number(e.archive.to_double()),
          "offset": Json::number(e.offset.to_double()),
          "length": Json::number(e.length.to_double()),
          "preload_bytes": Json::number(e.preload.length().to_double()),
          "crc32": Json::string(e.crc32.to_string()),
        })
      }),
    ),
  })
}

///|
pub fn DependencyGraph::to_json(self : DependencyGraph) -> Json {
  Json::object({
    "roots": Json::array(self.roots.map(Json::string)),
    "files": Json::array(
      self
      .files()
      .map(f => {
        Json::object({
          "path": Json::string(f.path),
          "mount": Json::string(f.mount),
          "base_game": Json::boolean(f.base_game),
          "size": Json::number(f.bytes.length().to_double()),
        })
      }),
    ),
    "edges": Json::array(
      self.edges.map(e => {
        Json::object({
          "source": Json::string(e.source),
          "reference": Json::string(e.reference),
          "target": match e.target {
            Some(s) => Json::string(s)
            None => Json::null()
          },
          "kind": Json::string(e.kind),
          "property": Json::array(e.property.map(Json::string)),
          "status": Json::string(e.status),
        })
      }),
    ),
  })
}

///|
pub fn VMTMaterial::to_json(self : VMTMaterial) -> Json raise {
  self.stringify() |> ignore
  Json::object({
    "shader": Json::string(self.shader),
    "parameters": entries_to_json(self.parameters),
    "includes": Json::array(self.includes.map(Json::string)),
    "origins": Json::array(
      self.origins.map(o => {
        Json::object({
          "path": Json::array(o.path.map(n => Json::number(n.to_double()))),
          "source": Json::string(o.source),
          "operation": Json::string(o.operation),
        })
      }),
    ),
    "textures": Json::array(
      self
      .textures()
      .map(t => {
        Json::object({
          "path": Json::array(t.path.map(Json::string)),
          "parameter": Json::string(t.parameter),
          "value": Json::string(t.value),
          "target": match t.target {
            Some(s) => Json::string(s)
            None => Json::null()
          },
          "status": Json::string(t.status),
        })
      }),
    ),
  })
}

///|
pub fn Localization::to_json(self : Localization) -> Json raise {
  localization_validate(self)
  Json::object({
    "language": Json::string(self.language),
    "encoding": Json::string(self.encoding),
    "tokens": Json::array(
      self.tokens.map(t => {
        Json::object({
          "name": Json::string(t.name),
          "text": Json::string(t.text),
        })
      }),
    ),
  })
}

///|
pub fn localization_issues_to_json(issues : Array[LocalizationIssue]) -> Json {
  Json::array(
    issues.map(i => {
      Json::object({
        "token": Json::string(i.token),
        "code": Json::string(i.code),
        "message": Json::string(i.message),
      })
    }),
  )
}

///|
pub fn localization_from_json(json : Json) -> Localization raise {
  guard json is Object(fields) &&
    fields.length() == 3 &&
    fields.get("tokens") is Some(Array(tokens)) &&
    tokens.length() <= 100000 else {
    raise InvalidDocument("Invalid localization JSON")
  }
  let document = Localization::{
    language: dmx_json_string(fields, "language"),
    encoding: dmx_json_string(fields, "encoding"),
    tokens: tokens.map(token => {
      guard token is Object(row) && row.length() == 2 else {
        raise InvalidDocument("Invalid localization token JSON")
      }
      LocalizationToken::{
        name: dmx_json_string(row, "name"),
        text: dmx_json_string(row, "text"),
      }
    }),
  }
  localization_validate(document)
  document
}
