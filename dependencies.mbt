///|
pub(all) struct AssetDependency {
  source : String
  reference : String
  target : String?
  kind : String
  property : Array[String]
  status : String
} derive(Eq, Debug)

///|
pub extend AssetDependency with Eq::{equal, not_equal}

///|
pub extend AssetDependency with @debug.Debug::{to_repr}

///|
struct DependencyGraph {
  roots : Array[String]
  nodes : Map[String, MountedFile]
  edges : Array[AssetDependency]
}

///|
pub fn DependencyGraph::edges(self : DependencyGraph) -> Array[AssetDependency] {
  self.edges.copy()
}

///|
pub fn DependencyGraph::files(self : DependencyGraph) -> Array[MountedFile] {
  let files = self.nodes.values().collect()
  files.sort_by((a, b) => a.path.lexical_compare(b.path))
  files
}

///|
fn asset_reference(
  source : String,
  reference : String,
  kind : String,
  property : Array[String],
) -> AssetDependency {
  let reference = reference.replace_all(old="\\", new="/")
  let valid = resource_relative(reference)
  {
    source,
    reference,
    target: if valid {
      Some(reference)
    } else {
      None
    },
    kind,
    property,
    status: if valid {
      "pending"
    } else {
      "dynamic"
    },
  }
}

///|
fn asset_kv3(
  value : KV3Value,
  source : String,
  path : Array[String],
  edges : Array[AssetDependency],
) -> Unit {
  match value {
    KV3Flag(flag, inner) => {
      if flag == "resource" || flag == "resource_name" {
        match inner {
          KV3String(resource) => {
            let target = resource +
              (if resource.to_lower().has_suffix("_c") { "" } else { "_c" })
            edges.push(asset_reference(source, target, "kv3-" + flag, path))
          }
          _ =>
            edges.push({
              source,
              reference: flag,
              target: None,
              kind: "kv3-" + flag,
              property: path,
              status: "dynamic",
            })
        }
      }
      asset_kv3(inner, source, path, edges)
    }
    KV3Object(entries) =>
      for entry in entries {
        asset_kv3(entry.value, source, path + [entry.key], edges)
      }
    KV3Array(values) =>
      for i in 0..<values.length() {
        asset_kv3(values[i], source, path + [i.to_string()], edges)
      }
    _ => ()
  }
}

///|
fn asset_scan(
  file : MountedFile,
  filesystem : GameFileSystem,
) -> Array[AssetDependency] raise {
  let edges : Array[AssetDependency] = []
  let path = file.path
  let lower = path.to_lower()
  if lower.has_suffix(".vmt") {
    let material = parse_vmt(@utf8.decode(file.bytes[:]), source=path)
    if material.shader.to_lower() == "patch" {
      guard game_child(material.parameters, "include") is Some(Text(target)) else {
        raise InvalidReference("VMT Patch include was not found")
      }
      edges.push(asset_reference(path, target, "vmt-include", ["include"]))
      // Resolve only when the include is present, so missing includes are
      // represented as graph diagnostics instead of losing the whole graph.
      if resource_relative(target) && !filesystem.locate(target).is_empty() {
        let expanded = load_vmt(path, p => {
          @utf8.decode(filesystem.read(p).bytes[:])
        })
        for texture in expanded.textures() {
          edges.push({
            source: path,
            reference: texture.value,
            target: texture.target,
            kind: "vmt-texture",
            property: texture.path,
            status: if texture.status == "file" {
              "pending"
            } else {
              texture.status
            },
          })
        }
      }
    } else {
      for texture in material.textures() {
        edges.push({
          source: path,
          reference: texture.value,
          target: texture.target,
          kind: "vmt-texture",
          property: texture.path,
          status: if texture.status == "file" {
            "pending"
          } else {
            texture.status
          },
        })
      }
    }
  } else if lower.has_suffix(".kv3") {
    let binary = file.bytes.length() >= 4 &&
      (
        (
          file.bytes[0] >= b'\x01' &&
          file.bytes[0] <= b'\x05' &&
          file.bytes[1] == b'3' &&
          file.bytes[2] == b'V' &&
          file.bytes[3] == b'K'
        ) ||
        file.bytes[:4].to_owned() == b"VKV\x03"
      )
    let doc = if binary {
      decode_kv3_binary(file.bytes).document()
    } else {
      parse_kv3(@utf8.decode(file.bytes[:]))
    }
    asset_kv3(doc.root, path, [], edges)
  } else if lower.has_suffix("_c") {
    let container = read_resource_container(file.bytes)
    for external in container.external_references() {
      let target = external.name +
        (if external.name.to_lower().has_suffix("_c") { "" } else { "_c" })
      edges.push(
        asset_reference(path, target, "rerl", [external.id.to_string()]),
      )
    }
    let mut inspected = false
    for block in container.blocks {
      if block.kind == "DATA" && block.bytes.length() >= 4 {
        let magic = valve_bytes(block.bytes).uint(4)
        if magic == 0x03564b56UL ||
          (magic >= 0x4b563301UL && magic <= 0x4b563305UL) {
          asset_kv3(
            decode_kv3_binary(block.bytes).document().root,
            path,
            [],
            edges,
          )
          inspected = true
        }
      }
    }
    if !inspected &&
      ![".vtex_c", ".vsnd_c"].any(suffix => lower.has_suffix(suffix)) {
      edges.push({
        source: path,
        reference: path,
        target: None,
        kind: "unscanned-resource-data",
        property: [],
        status: "opaque",
      })
    }
  } else if [".vdf", ".txt", ".res"].any(suffix => lower.has_suffix(suffix)) {
    let (document, _) = parse_internal(
      @utf8.decode(file.bytes[:]),
      ParseOptions::default(),
      true,
    )
    for entry in document.entries {
      if entry.key == "#include" || entry.key == "#base" {
        guard entry.value is Text(target) else {
          raise InvalidReference("File directive requires text")
        }
        edges.push(
          asset_reference(
            path,
            child_reference(path, target),
            "kv1-" + entry.key,
            [entry.key],
          ),
        )
      }
    }
  } else if ![".vtf", ".png", ".jpg", ".jpeg", ".wav", ".mp3", ".ogg", ".webm"].any(suffix => {
        lower.has_suffix(suffix)
      },
    ) {
    edges.push({
      source: path,
      reference: path,
      target: None,
      kind: "unscanned-format",
      property: [],
      status: "opaque",
    })
  }
  edges
}

///|
/// Build a bounded transitive graph from an explicit mounted filesystem.
/// Missing, dynamic and opaque references stay visible; base-game files retain
/// their provenance and can be excluded from export without marking them missing.
pub fn build_dependency_graph(
  roots : Array[String],
  filesystem : GameFileSystem,
  max_files~ : Int32 = 2048,
  max_bytes~ : Int32 = 67108864,
) -> DependencyGraph raise {
  if roots.is_empty() ||
    roots.length() > max_files ||
    max_files < 1 ||
    max_files > 10000 ||
    max_bytes < 1 ||
    max_bytes > 268435456 {
    raise InvalidReference("Invalid dependency graph budgets")
  }
  let roots = roots.map(p => game_virtual_path(p))
  let queue = roots.copy()
  let nodes : Map[String, MountedFile] = Map([])
  let seen : Map[String, Bool] = Map([])
  let edges : Array[AssetDependency] = []
  let mut cursor = 0
  let mut total = 0
  while cursor < queue.length() {
    let path = queue[cursor]
    cursor += 1
    if seen.contains(path.to_lower()) {
      continue
    }
    seen[path.to_lower()] = true
    if seen.length() > max_files {
      raise InvalidReference("Dependency file budget exceeded")
    }
    if filesystem.locate(path).is_empty() {
      continue
    }
    let file = filesystem.read(path)
    if file.bytes.length() > max_bytes - total {
      raise InvalidReference("Dependency aggregate bytes exceeded")
    }
    total += file.bytes.length()
    nodes[path.to_lower()] = file
    let scanned = asset_scan(file, filesystem)
    if scanned.length() > 100000 - edges.length() {
      raise InvalidReference("Dependency edge budget exceeded")
    }
    for edge in scanned {
      let edge = if edge.target is Some(target) {
        let found = filesystem.locate(target)
        if found.is_empty() {
          { ..edge, status: "missing", }
        } else {
          queue.push(target)
          {
            ..edge,
            status: if found[0].base_game {
              "base-game"
            } else {
              "resolved"
            },
          }
        }
      } else {
        edge
      }
      edges.push(edge)
    }
  }
  for root in roots {
    if !nodes.contains(root.to_lower()) {
      edges.push({
        source: "",
        reference: root,
        target: Some(root),
        kind: "root",
        property: [],
        status: "missing",
      })
    }
  }
  { roots: roots.copy(), nodes, edges, }
}

///|
pub fn DependencyGraph::dependents(
  self : DependencyGraph,
  target : String,
  transitive~ : Bool = true,
) -> Array[String] {
  let queue = [target.to_lower()]
  let seen : Map[String, Bool] = Map([])
  seen[target.to_lower()] = true
  let output : Array[String] = []
  let mut i = 0
  while i < queue.length() {
    let current = queue[i]
    i += 1
    for edge in self.edges {
      if edge.target.map(p => p.to_lower()) == Some(current) &&
        !seen.contains(edge.source.to_lower()) &&
        !edge.source.is_empty() {
        seen[edge.source.to_lower()] = true
        output.push(edge.source)
        if transitive {
          queue.push(edge.source.to_lower())
        }
      }
    }
  }
  output.sort_by((a, b) => a.lexical_compare(b))
  output
}

///|
pub fn DependencyGraph::export_files(
  self : DependencyGraph,
  include_base~ : Bool = false,
  strict~ : Bool = true,
) -> Map[String, Bytes] raise {
  if strict &&
    self.edges.any(e => ["missing", "dynamic", "opaque"].contains(e.status)) {
    raise InvalidReference(
      "Dependency closure has unresolved or unscanned references",
    )
  }
  let output : Map[String, Bytes] = Map([])
  for file in self.nodes.values() {
    if include_base || !file.base_game {
      output[file.path] = file.bytes
    }
  }
  if output.is_empty() && !self.roots.is_empty() {
    raise InvalidReference("Dependency export is empty")
  }
  output
}

///|
pub fn DependencyGraph::export_vpk(
  self : DependencyGraph,
  include_base~ : Bool = false,
  strict~ : Bool = true,
  options~ : BinaryOptions = BinaryOptions::default(),
) -> Bytes raise {
  create_vpk(self.export_files(include_base~, strict~), options~)
}

///|
pub fn DependencyGraph::export_zip(
  self : DependencyGraph,
  include_base~ : Bool = false,
  strict~ : Bool = true,
) -> Bytes raise {
  export_files_zip(self.export_files(include_base~, strict~))
}
