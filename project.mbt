///|
priv struct TraceNode {
  offset : Int32
  line : Int32
  column : Int32
  children : Array[TraceNode]
}

///|
pub(all) struct SourceLocation {
  source : String
  offset : Int32
  line : Int32
  column : Int32
} derive(Eq, Debug)

///|
pub(all) struct ResolvedOrigin {
  path : Array[Selector]
  location : SourceLocation
} derive(Eq, Debug)

///|
pub(all) struct ReferenceEdge {
  source : String
  target : String
  kind : String
  location : SourceLocation
} derive(Eq, Debug)

///|
pub(all) struct ResolvedProject {
  document : Document
  origins : Array[ResolvedOrigin]
  references : Array[ReferenceEdge]
} derive(Eq, Debug)

///|
pub extend SourceLocation with Eq::{equal, not_equal}

///|
pub extend SourceLocation with @debug.Debug::{to_repr}

///|
pub extend ResolvedOrigin with Eq::{equal, not_equal}

///|
pub extend ResolvedOrigin with @debug.Debug::{to_repr}

///|
pub extend ReferenceEdge with Eq::{equal, not_equal}

///|
pub extend ReferenceEdge with @debug.Debug::{to_repr}

///|
pub extend ResolvedProject with Eq::{equal, not_equal}

///|
pub extend ResolvedProject with @debug.Debug::{to_repr}

///|
priv struct ResolvedNode {
  entry : Entry
  location : SourceLocation
  children : Array[ResolvedNode]
}

///|
fn traced_nodes(
  entries : Array[Entry],
  traces : Array[TraceNode],
  source : String,
) -> Array[ResolvedNode] {
  entries.mapi((i, entry) => {
    let trace = traces[i]
    let children = match entry.value {
      Object(entries) => traced_nodes(entries, trace.children, source)
      _ => []
    }
    {
      entry,
      location: {
        source,
        offset: trace.offset,
        line: trace.line,
        column: trace.column,
      },
      children,
    }
  })
}

///|
fn collect_origins(
  nodes : Array[ResolvedNode],
  path : Array[Selector],
  output : Array[ResolvedOrigin],
) -> Unit {
  let occurrences : Map[String, Int32] = Map([])
  for node in nodes {
    let occurrence = occurrences.get(node.entry.key).unwrap_or(0)
    occurrences[node.entry.key] = occurrence + 1
    let next = path.map(p => p)
    next.push({ key: node.entry.key, occurrence, })
    output.push({ path: next, location: node.location, })
    collect_origins(node.children, next, output)
  }
}

///|
/// The resolver and provenance use one merge operation. Locations identify key
/// starts in the original files, before filtering or formatting, in scalar units.
pub fn load_project(
  source : String,
  loader : (String) -> String raise,
  options~ : ParseOptions = ParseOptions::default(),
  max_files~ : Int32 = 64,
) -> ResolvedProject raise {
  if max_files < 1 || max_files > 256 {
    raise InvalidReference("max_files must be between 1 and 256")
  }
  let state = ResolveState::{
    options,
    max_files,
    files: 0,
    chars: 0,
    entries: 0,
    references: [],
  }
  let nodes = resolve_file(normalize_reference(source), loader, [], state)
  let origins : Array[ResolvedOrigin] = []
  collect_origins(nodes, [], origins)
  {
    document: { entries: nodes.map(n => n.entry), },
    origins,
    references: state.references,
  }
}

///|
fn location_json(location : SourceLocation) -> Json {
  Json::object({
    "source": Json::string(location.source),
    "offset": Json::number(location.offset.to_double()),
    "line": Json::number(location.line.to_double()),
    "column": Json::number(location.column.to_double()),
  })
}

///|
pub fn ResolvedProject::to_json(self : ResolvedProject) -> Json {
  Json::object({
    "tree": self.document.to_json(),
    "origins": Json::array(
      self.origins.map(origin => {
        Json::object({
          "path": Json::array(
            origin.path.map(p => {
              Json::object({
                "key": Json::string(p.key),
                "occurrence": Json::number(p.occurrence.to_double()),
              })
            }),
          ),
          "location": location_json(origin.location),
        })
      }),
    ),
    "references": Json::array(
      self.references.map(edge => {
        Json::object({
          "source": Json::string(edge.source),
          "target": Json::string(edge.target),
          "kind": Json::string(edge.kind),
          "location": location_json(edge.location),
        })
      }),
    ),
  })
}

///|
/// Raw source locations include branches and directives without evaluation.
pub fn SourceDocument::locations(
  self : SourceDocument,
  source : String,
) -> Array[ResolvedOrigin] {
  let spans : Map[String, SourceSpan] = Map([])
  for span in self.spans {
    spans[span.path.map(i => i.to_string()).join("/")] = span
  }
  let starts : Map[Int32, Array[Selector]] = Map([])
  source_paths(self.doc.entries, "", [], spans, starts)
  let result : Array[ResolvedOrigin] = []
  let mut line = 1
  let mut column = 1
  let mut cr = false
  for i in 0..<self.chars.length() {
    if starts.get(i) is Some(selectors) {
      result.push({
        path: selectors,
        location: { source, offset: i, line, column, },
      })
    }
    let c = self.chars[i]
    if c == '\r' {
      line += 1
      column = 1
    } else if c == '\n' {
      if !cr {
        line += 1
      }
      column = 1
    } else {
      column += 1
    }
    cr = c == '\r'
  }
  result
}

///|
fn source_paths(
  entries : Array[Entry],
  prefix : String,
  path : Array[Selector],
  spans : Map[String, SourceSpan],
  starts : Map[Int32, Array[Selector]],
) -> Unit {
  let occurrences : Map[String, Int32] = Map([])
  for i in 0..<entries.length() {
    let entry = entries[i]
    let occurrence = occurrences.get(entry.key).unwrap_or(0)
    occurrences[entry.key] = occurrence + 1
    let next = path.map(p => p)
    next.push({ key: entry.key, occurrence, })
    let key = prefix + i.to_string()
    if spans.get(key) is Some(span) {
      starts[span.key_start] = next
    }
    if entry.value is Object(children) {
      source_paths(children, key + "/", next, spans, starts)
    }
  }
}
