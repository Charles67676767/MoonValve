///|
/// Map a resource path prefix to an explicit directory, never an inferred game root.
pub(all) struct ResourceRoot {
  prefix : String
  directory : String
} derive(Eq, Debug)

///|
pub extend ResourceRoot with Eq::{equal, not_equal}

///|
pub extend ResourceRoot with @debug.Debug::{to_repr}

///|
pub(all) struct ResourceReference {
  path : Array[String]
  resource : String
  target : String?
  status : String
  start : Int
  end : Int
} derive(Eq, Debug)

///|
pub extend ResourceReference with Eq::{equal, not_equal}

///|
pub extend ResourceReference with @debug.Debug::{to_repr}

///|
pub fn resource_roots_from_json(json : Json) -> Array[ResourceRoot] raise {
  guard json is Array(rows) && rows.length() <= 32 else {
    raise InvalidReference("Expected at most 32 resource roots")
  }
  let roots = rows.map(row => {
    guard row is Object(fields) &&
      fields.length() == 2 &&
      fields.get("prefix") is Some(String(prefix)) &&
      fields.get("directory") is Some(String(directory)) else {
      raise InvalidReference("Resource root requires prefix and directory")
    }
    ResourceRoot::{ prefix, directory, }
  })
  resource_roots(roots)
  roots
}

///|
fn resource_relative(path : String) -> Bool {
  !path.is_empty() &&
  path.length() <= 4096 &&
  !path.has_prefix("/") &&
  !path.contains("\\") &&
  !path.contains(":") &&
  !path.to_array().any(c => c.to_int() < 32 || c.to_int() == 127) &&
  path.split("/").all(p => p != "" && p != "." && p != "..")
}

///|
fn resource_roots(roots : Array[ResourceRoot]) -> Unit raise {
  if roots.length() > 32 {
    raise InvalidReference("At most 32 resource roots")
  }
  let prefixes : Map[String, Bool] = Map([])
  for root in roots {
    if prefixes.contains(root.prefix) ||
      (
        !root.prefix.is_empty() &&
        (
          !root.prefix.has_suffix("/") ||
          !resource_relative(root.prefix[:root.prefix.length() - 1].to_owned())
        )
      ) ||
      root.directory.is_empty() ||
      root.directory.length() > 32768 ||
      root.directory.contains("\\") ||
      root.directory.to_array().any(c => c.to_int() < 32) ||
      (
        root.directory != "." &&
        normalize_reference(root.directory) != root.directory
      ) {
      raise InvalidReference(
        "Resource roots require unique relative prefixes and normalized directories",
      )
    }
    prefixes[root.prefix] = true
  }
}

///|
fn resource_target(path : String, roots : Array[ResourceRoot]) -> String? raise {
  let mut best : ResourceRoot? = None
  for root in roots {
    if path.has_prefix(root.prefix) &&
      (best is None || root.prefix.length() > best.unwrap().prefix.length()) {
      best = Some(root)
    }
  }
  best.map(root => {
    normalize_reference(
      root.directory + "/" + path[root.prefix.length():].to_owned(),
    )
  })
}

///|
/// Only resource:"path" is a file reference. resource_name, soundevent and
/// localization/entity names are deliberately not guessed to be filesystem paths.
pub fn KV3SourceDocument::resources(
  self : KV3SourceDocument,
  roots? : Array[ResourceRoot] = [],
) -> Array[ResourceReference] raise {
  resource_roots(roots)
  let result : Array[ResourceReference] = []
  fn walk(
    value : KV3Value,
    indices : Array[Int],
    path : Array[String],
  ) -> Unit raise {
    if value is KV3Flag(flag, KV3String(resource)) && flag == "resource" {
      if result.length() >= 10000 {
        raise InvalidReference("Resource query exceeds 10000 references")
      }
      let valid = resource_relative(resource)
      let target = if valid { resource_target(resource, roots) } else { None }
      let span = self.spans[index_key(indices)]
      result.push({
        path,
        resource,
        target,
        start: span.start,
        end: span.end,
        status: if resource.is_empty() {
          "empty"
        } else if !valid {
          "invalid"
        } else if roots.is_empty() {
          "unconfigured"
        } else if target is None {
          "unmapped"
        } else {
          "resolved"
        },
      })
    }
    match kv3_unflag(value) {
      KV3Object(entries) =>
        for i in 0..<entries.length() {
          walk(entries[i].value, indices + [i], path + [entries[i].key])
        }
      KV3Array(values) =>
        for i in 0..<values.length() {
          walk(values[i], indices + [i], path + [i.to_string()])
        }
      _ => ()
    }
  }
  walk(self.doc.root, [], [])
  result
}

///|
pub fn resource_references_to_json(
  references : Array[ResourceReference],
) -> Json {
  Json::array(
    references.map(r => {
      Json::object({
        "path": Json::array(r.path.map(s => Json::string(s))),
        "resource": Json::string(r.resource),
        "target": match r.target {
          Some(s) => Json::string(s)
          None => Json::null()
        },
        "status": Json::string(r.status),
        "start": Json::number(r.start.to_double()),
        "end": Json::number(r.end.to_double()),
      })
    }),
  )
}

///|
fn resource_inverse(
  target : String,
  roots : Array[ResourceRoot],
) -> String raise {
  let mut best : ResourceRoot? = None
  for root in roots {
    let directory = if root.directory == "." {
      ""
    } else if root.directory == "/" {
      "/"
    } else {
      root.directory + "/"
    }
    if target.has_prefix(directory) &&
      (best is None || directory.length() > best.unwrap().directory.length()) {
      best = Some(root)
    }
  }
  guard best is Some(root) else {
    raise InvalidReference("Moved resource leaves configured directories")
  }
  let directory = if root.directory == "." {
    ""
  } else if root.directory == "/" {
    "/"
  } else {
    root.directory + "/"
  }
  let result = root.prefix + target[directory.length():].to_owned()
  if !resource_relative(result) ||
    resource_target(result, roots) != Some(target) {
    raise InvalidReference("Destination resource mapping is ambiguous")
  }
  result
}

///|
/// Return a source-preserving reference preview for file or directory moves.
/// This does not move asset bytes. Only original targets are matched, once.
pub fn KV3SourceDocument::rewrite_resources(
  self : KV3SourceDocument,
  roots : Array[ResourceRoot],
  moves : Map[String, String],
) -> KV3SourceDocument raise {
  resource_roots(roots)
  if moves.length() > 64 {
    raise InvalidReference("At most 64 resource moves")
  }
  let pairs = moves.iter().collect()
  for i in 0..<pairs.length() {
    let (from, to) = pairs[i]
    if from.is_empty() ||
      to.is_empty() ||
      normalize_reference(from) != from ||
      normalize_reference(to) != to ||
      from == to ||
      to.has_prefix(from + "/") ||
      from.contains("\\") ||
      to.contains("\\") {
      raise InvalidReference("Invalid resource move")
    }
    for j in 0..<i {
      let (a, b) = pairs[j]
      if from == a ||
        from.has_prefix(a + "/") ||
        a.has_prefix(from + "/") ||
        to == b ||
        to.has_prefix(b + "/") ||
        b.has_prefix(to + "/") ||
        from == b ||
        from.has_prefix(b + "/") ||
        b.has_prefix(from + "/") ||
        to == a ||
        to.has_prefix(a + "/") ||
        a.has_prefix(to + "/") {
        raise InvalidReference("Overlapping or chained resource moves")
      }
    }
  }
  let patches : Array[TextPatch] = []
  let operations : Map[String, KV3Edit] = Map([])
  let indices_by_start : Map[Int, String] = Map([])
  for key, span in self.spans {
    indices_by_start[span.start] = key
  }
  for reference in self.resources(roots~) {
    guard reference.target is Some(target) else { continue }
    let next = lsp_moved(target, pairs)
    if next == target {
      continue
    }
    let resource = resource_inverse(next, roots)
    let value = KV3Flag("resource", KV3String(resource))
    operations[indices_by_start[reference.start]] = KV3Replace(value)
  }
  if operations.is_empty() {
    self
  } else {
    let root = self.snapshot_value(self.doc.root, [], operations, patches, "\n")
    self.patched(patches, { header: self.doc.header, root, })
  }
}
