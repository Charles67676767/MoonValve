///|
pub(all) enum CacheFormat {
  AppInfo
  PackageInfo
} derive(Eq, Debug)

///|
pub extend CacheFormat with Eq::{equal, not_equal}

///|
pub extend CacheFormat with @debug.Debug::{to_repr}

///|
pub(all) struct CacheRecord {
  id : UInt
  change_number : UInt
  token : UInt64
  sha1 : Bytes
  binary_sha1 : Bytes?
  info_state : UInt?
  last_updated : UInt?
  offset : Int
  length : Int
} derive(Eq, Debug)

///|
pub extend CacheRecord with Eq::{equal, not_equal}

///|
pub extend CacheRecord with @debug.Debug::{to_repr}

///|
/// An index owns a snapshot of the input. AppInfo payloads are decoded only when
/// requested. PackageInfo has no record sizes, so indexing validates each tree.
struct SteamCache {
  bytes : Bytes
  kind : CacheFormat
  revision : Int
  universe_id : UInt
  rows : Array[CacheRecord]
  strings : Array[String]?
  options : BinaryOptions
}

///|
pub fn SteamCache::format(self : SteamCache) -> CacheFormat {
  self.kind
}

///|
pub fn SteamCache::version(self : SteamCache) -> Int {
  self.revision
}

///|
pub fn SteamCache::universe(self : SteamCache) -> UInt {
  self.universe_id
}

///|
pub fn SteamCache::records(self : SteamCache) -> Array[CacheRecord] {
  self.rows.map(r => r)
}

///|
pub fn SteamCache::read(
  self : SteamCache,
  id : UInt,
) -> Array[BinaryEntry]? raise BinaryError {
  for row in self.rows {
    if row.id == id {
      return Some(
        decode_binary(
          self.bytes[row.offset:row.offset + row.length].to_owned(),
          options=self.options,
          string_table=self.strings,
        ),
      )
    }
  }
  None
}

///|
fn BinaryReader::take(
  self : BinaryReader,
  length : Int,
) -> Bytes raise BinaryError {
  if length < 0 || length > self.bytes.length() - self.pos {
    raise InvalidBinary(self.pos, "Truncated cache field")
  }
  let result = self.bytes[self.pos:self.pos + length].to_owned()
  self.pos += length
  result
}

///|
/// Supported cache revisions: appinfo 39/40/41, packageinfo 39/40. Record bounds,
/// table offsets, identifiers, sentinels and trailing data are checked strictly.
pub fn open_steam_cache(
  input : Bytes,
  max_bytes? : Int = 536870912,
  max_records? : Int = 1000000,
) -> SteamCache raise BinaryError {
  if max_bytes < 8 ||
    max_records < 0 ||
    max_records > 1000000 ||
    input.length() > max_bytes {
    raise InvalidBinary(0, "Invalid cache limits or oversized input")
  }
  let options = { ..BinaryOptions::default(), max_bytes, max_entries: 1000000, }
  let bytes = input
  let r = BinaryReader::{ bytes, options, pos: 0, count: 0, table: None, }
  let magic = r.number(4).to_uint()
  let revision = (magic & 255U).reinterpret_as_int()
  let kind = if magic >> 8 == 0x075644U && revision >= 39 && revision <= 41 {
    CacheFormat::AppInfo
  } else if magic >> 8 == 0x065655U && revision >= 39 && revision <= 40 {
    PackageInfo
  } else {
    raise InvalidBinary(0, "Unsupported Steam cache header or revision")
  }
  let universe_id = r.number(4).to_uint()
  let mut table_start = bytes.length()
  let mut strings : Array[String]? = None
  if kind == AppInfo && revision == 41 {
    let offset = r.number(8)
    if offset < 20UL || offset > bytes.length().to_uint64() {
      raise InvalidBinary(8, "Invalid string table offset")
    }
    table_start = offset.to_int()
    let table = BinaryReader::{
      bytes,
      options,
      pos: table_start,
      count: 0,
      table: None,
    }
    let count = table.number(4)
    if count > 1000000UL {
      raise InvalidBinary(table_start, "String table count exceeds limit")
    }
    let pool : Array[String] = []
    for _ in 0..<count.to_int() {
      pool.push(table.cstring(false))
    }
    if table.pos != bytes.length() {
      raise InvalidBinary(table.pos, "Trailing string table data")
    }
    strings = Some(pool)
    validate_string_table(strings, options) |> ignore
  }
  let rows : Array[CacheRecord] = []
  let ids : Map[UInt, Bool] = Map([])
  while true {
    if r.pos + 4 > table_start {
      raise InvalidBinary(r.pos, "Missing cache sentinel")
    }
    let id = r.number(4).to_uint()
    if (kind == AppInfo && id == 0U) ||
      (kind == PackageInfo && id == 0xffffffffU) {
      break
    }
    if rows.length() >= max_records || ids.contains(id) {
      raise InvalidBinary(r.pos - 4, "Record limit or duplicate identifier")
    }
    ids[id] = true
    let mut end = table_start
    let mut info_state = None
    let mut last_updated = None
    let mut token = 0UL
    if kind == AppInfo {
      let size = r.number(4)
      if r.pos > table_start ||
        size < (if revision >= 40 { 61UL } else { 41UL }) ||
        size > (table_start - r.pos).to_uint64() {
        raise InvalidBinary(r.pos - 4, "Invalid appinfo record size")
      }
      end = r.pos + size.to_int()
      info_state = Some(r.number(4).to_uint())
      last_updated = Some(r.number(4).to_uint())
      token = r.number(8)
    }
    let sha1 = r.take(20)
    let change_number = r.number(4).to_uint()
    let binary_sha1 = if kind == AppInfo && revision >= 40 {
      Some(r.take(20))
    } else {
      None
    }
    if kind == PackageInfo && revision >= 40 {
      token = r.number(8)
    }
    let offset = r.pos
    if kind == PackageInfo {
      r.read_binary_entries(0) |> ignore
      end = r.pos
    } else {
      r.pos = end
    }
    rows.push({
      id,
      change_number,
      token,
      sha1,
      binary_sha1,
      info_state,
      last_updated,
      offset,
      length: end - offset,
    })
  }
  if r.pos != table_start {
    raise InvalidBinary(r.pos, "Trailing cache bytes before string table")
  }
  { bytes, kind, revision, universe_id, rows, strings, options, }
}
