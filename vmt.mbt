///|
pub(all) struct VMTOrigin {
  path : Array[Int]
  source : String
  operation : String
} derive(Eq, Debug)

///|
pub(all) struct VMTMaterial {
  shader : String
  parameters : Array[Entry]
  origins : Array[VMTOrigin]
  includes : Array[String]
} derive(Eq, Debug)

///|
pub(all) struct VMTTexture {
  path : Array[String]
  parameter : String
  value : String
  target : String?
  status : String
} derive(Eq, Debug)

///|
pub extend VMTOrigin with Eq::{equal, not_equal}

///|
pub extend VMTOrigin with @debug.Debug::{to_repr}

///|
pub extend VMTMaterial with Eq::{equal, not_equal}

///|
pub extend VMTMaterial with @debug.Debug::{to_repr}

///|
pub extend VMTTexture with Eq::{equal, not_equal}

///|
pub extend VMTTexture with @debug.Debug::{to_repr}

///|
priv struct VMTNode {
  key : String
  value : String?
  children : Array[VMTNode]
  source : String
  operation : String
}

///|
fn vmt_nodes(
  entries : Array[Entry],
  source : String,
  operation : String,
) -> Array[VMTNode] {
  entries.map(e => {
    match e.value {
      Text(text) =>
        { key: e.key, value: Some(text), children: [], source, operation, }
      Object(children) =>
        {
          key: e.key,
          value: None,
          children: vmt_nodes(children, source, operation),
          source,
          operation,
        }
    }
  })
}

///|
fn vmt_entries(
  nodes : Array[VMTNode],
  path : Array[Int],
  origins : Array[VMTOrigin],
) -> Array[Entry] {
  nodes.mapi((i, node) => {
    let path = path + [i]
    origins.push({ path, source: node.source, operation: node.operation, })
    {
      key: node.key,
      value: match node.value {
        Some(s) => Text(s)
        None => Object(vmt_entries(node.children, path, origins))
      },
    }
  })
}

///|
fn vmt_read(
  text : String,
  options : ParseOptions,
) -> (String, Array[Entry]) raise {
  let doc = parse(text, options~)
  guard doc.entries.length() == 1 && doc.entries[0].value is Object(parameters) else {
    raise InvalidReference("VMT requires one shader object")
  }
  (doc.entries[0].key, parameters)
}

///|
pub fn parse_vmt(
  text : String,
  source? : String = "material.vmt",
  options? : ParseOptions = ParseOptions::default(),
) -> VMTMaterial raise {
  let (shader, entries) = vmt_read(text, options)
  let origins : Array[VMTOrigin] = []
  let parameters = vmt_entries(
    vmt_nodes(entries, source, "source"),
    [],
    origins,
  )
  { shader, parameters, origins, includes: [], }
}

///|
fn vmt_patch(
  base : Array[VMTNode],
  patch : Array[VMTNode],
  replace : Bool,
  depth : Int,
) -> Array[VMTNode] raise {
  if depth > 128 {
    raise InvalidReference("VMT patch depth exceeded")
  }
  let output = base.copy()
  for node in patch {
    let key = node.key.to_lower()
    let mut found : Int? = None
    for i in 0..<output.length() {
      if output[i].key.to_lower() == key {
        found = Some(i)
        break
      }
    }
    if node.value is Some(text) {
      if text.is_empty() {
        if found is Some(i) {
          output.remove(i) |> ignore
        }
      } else if found is Some(i) {
        output[i] = { ..node, key: output[i].key, }
      } else if !replace {
        output.push(node)
      }
    } else if key == "proxies" {
      if found is Some(i) {
        if output[i].value is Some(_) {
          raise InvalidReference("VMT Proxies must be an object")
        }
        output[i] = {
          ..output[i],
          children: output[i].children + node.children,
        }
      } else {
        output.push(node)
      }
    } else if found is Some(i) {
      if output[i].value is Some(_) {
        raise InvalidReference("VMT patch changes parameter shape")
      }
      output[i] = {
        ..output[i],
        children: vmt_patch(
          output[i].children,
          node.children,
          replace,
          depth + 1,
        ),
      }
    } else if !replace {
      output.push(node)
    }
  }
  output
}

///|
fn vmt_expand(
  source : String,
  loader : (String) -> String raise,
  options : ParseOptions,
  stack : Array[String],
  includes : Array[String],
  chars : Ref[Int],
  max_files : Int,
) -> (String, Array[VMTNode]) raise {
  if stack.length() >= max_files || stack.contains(source.to_lower()) {
    raise InvalidReference("VMT Patch include cycle or file budget exceeded")
  }
  let text = loader(source)
  if text.char_length() > options.max_input_chars - chars.val {
    raise InvalidReference("VMT aggregate input budget exceeded")
  }
  chars.val += text.char_length()
  let (shader, entries) = vmt_read(text, options)
  if shader.to_lower() != "patch" {
    return (shader, vmt_nodes(entries, source, "source"))
  }
  let include_entries = entries.filter(e => e.key.to_lower() == "include")
  guard include_entries.length() == 1 &&
    include_entries[0].value is Text(target) else {
    raise InvalidReference("VMT Patch requires one include")
  }
  let target = game_virtual_path(target)
  if !target.to_lower().has_prefix("materials/") ||
    !target.to_lower().has_suffix(".vmt") {
    raise InvalidReference("VMT Patch include requires a materials/*.vmt path")
  }
  includes.push(target)
  let (shader, base) = vmt_expand(
    target,
    loader,
    options,
    stack + [source.to_lower()],
    includes,
    chars,
    max_files,
  )
  let mut result = base
  for entry in entries {
    let command = entry.key.to_lower()
    if command == "include" {
      continue
    }
    if command != "insert" && command != "replace" {
      raise InvalidReference("Unsupported VMT Patch command")
    }
    guard entry.value is Object(parameters) else {
      raise InvalidReference("VMT Patch command requires an object")
    }
    result = vmt_patch(
      result,
      vmt_nodes(parameters, source, command),
      command == "replace",
      0,
    )
  }
  (shader, result)
}

///|
/// Resolve Patch include/insert/replace through an explicit game-relative loader.
/// Origin indices address the expanded parameter tree, including repeated proxies.
pub fn load_vmt(
  source : String,
  loader : (String) -> String raise,
  options? : ParseOptions = ParseOptions::default(),
  max_files? : Int = 64,
) -> VMTMaterial raise {
  if max_files < 1 || max_files > 128 {
    raise InvalidReference("Invalid VMT file budget")
  }
  let includes : Array[String] = []
  let (shader, nodes) = vmt_expand(
    game_virtual_path(source),
    loader,
    options,
    [],
    includes,
    { val: 0, },
    max_files,
  )
  let origins : Array[VMTOrigin] = []
  let parameters = vmt_entries(nodes, [], origins)
  stringify({ entries: [{ key: shader, value: Object(parameters), }], })
  |> ignore
  { shader, parameters, origins, includes, }
}

///|
pub fn VMTMaterial::stringify(self : VMTMaterial) -> String raise {
  stringify({
    entries: [{ key: self.shader, value: Object(self.parameters), }],
  })
}

///|
fn vmt_texture_keys(extra : Array[String]) -> Array[String] {
  [
    "$basetexture", "$basetexture2", "$bumpmap", "$bumpmap2", "$normalmap", "$detail",
    "$detail2", "$envmap", "$envmapmask", "$phongexponenttexture", "$selfillummask",
    "$blendmodulatetexture", "$lightwarptexture", "$flowmap", "$flow_noise_texture",
    "$dudvmap", "$refracttinttexture",
  ] +
  extra.map(s => s.to_lower())
}

///|
fn vmt_textures(
  entries : Array[Entry],
  path : Array[String],
  keys : Array[String],
  output : Array[VMTTexture],
) -> Unit {
  for entry in entries {
    let child = path + [entry.key]
    match entry.value {
      Object(children) =>
        if entry.key.to_lower() != "proxies" {
          vmt_textures(children, child, keys, output)
        }
      Text(value) =>
        if keys.contains(entry.key.to_lower()) {
          let normalized = value.replace_all(old="\\", new="/")
          let lower = normalized.to_lower()
          let builtin = lower == "env_cubemap" || lower.has_prefix("_rt_")
          let dynamic = value.is_empty() ||
            value.contains("$") ||
            value.contains("%") ||
            !resource_relative(normalized)
          let target = if builtin || dynamic {
            None
          } else {
            Some(
              (if lower.has_prefix("materials/") {
                normalized
              } else {
                "materials/" + normalized
              }) +
              (if lower.has_suffix(".vtf") { "" } else { ".vtf" }),
            )
          }
          output.push({
            path: child,
            parameter: entry.key,
            value,
            target,
            status: if builtin {
              "builtin"
            } else if dynamic {
              "dynamic"
            } else {
              "file"
            },
          })
        }
    }
  }
}

///|
pub fn VMTMaterial::textures(
  self : VMTMaterial,
  extra_parameters? : Array[String] = [],
) -> Array[VMTTexture] raise {
  self.stringify() |> ignore
  let output : Array[VMTTexture] = []
  vmt_textures(self.parameters, [], vmt_texture_keys(extra_parameters), output)
  output
}

///|
/// Return a new material with one top-level parameter. Duplicate matches are
/// rejected so an edit cannot silently target a different effective parameter.
pub fn VMTMaterial::with_parameter(
  self : VMTMaterial,
  key : String,
  value : String,
) -> VMTMaterial raise {
  self.stringify() |> ignore
  let indices : Array[Int] = []
  for i in 0..<self.parameters.length() {
    if self.parameters[i].key.to_lower() == key.to_lower() {
      indices.push(i)
    }
  }
  if indices.length() > 1 {
    raise InvalidEdit("Ambiguous duplicate VMT parameter")
  }
  let entries = self.parameters.copy()
  if indices.is_empty() {
    entries.push({ key, value: Text(value), })
  } else {
    entries[indices[0]] = { key: entries[indices[0]].key, value: Text(value), }
  }
  let edited = if indices.is_empty() {
    entries.length() - 1
  } else {
    indices[0]
  }
  let origins = self.origins.filter(origin => {
    origin.path.is_empty() || origin.path[0] != edited
  })
  origins.push({ path: [edited], source: "edited.vmt", operation: "edit", })
  let result = { ..self, parameters: entries, origins, }
  result.stringify() |> ignore
  result
}
