///|
/// The host supplies bounded UTF-8 file IO; KV1 and Steam semantics are MoonBit.
extern "js" fn host_read_impl(path : String) -> FixedArray[String] =
  #| function(path) {
  #|   try {
  #|     const fs = require('node:fs');
  #|     const fd = path === '-' ? 0 : fs.openSync(path, 'r');
  #|     const chunks = [];
  #|     let total = 0;
  #|     try {
  #|       for (;;) {
  #|         const buffer = Buffer.alloc(65536);
  #|         const n = fs.readSync(fd, buffer, 0, buffer.length, null);
  #|         if (!n) break;
  #|         total += n;
  #|         if (total > 16 * 1024 * 1024) throw new Error('Input exceeds 16 MiB');
  #|         chunks.push(buffer.subarray(0, n));
  #|       }
  #|       return [new TextDecoder('utf-8', {fatal: true}).decode(Buffer.concat(chunks)), ''];
  #|     } finally { if (fd !== 0) fs.closeSync(fd); }
  #|   } catch (e) { return ['', e.message || 'Unable to read input']; }
  #| }

///|
extern "js" fn host_error(message : String, code : Int) -> Unit =
  #| function(message, code) { process.stderr.write(message + '\n'); process.exitCode = code; }

///|
extern "js" fn host_output(text : String) -> Unit =
  #| function(text) { process.stdout.write(text); }

///|
extern "js" fn host_manifest_paths(
  source : String,
  library : String,
) -> FixedArray[String] =
  #| function(source, library) {
  #|   try {
  #|     const fs = require('node:fs'), path = require('node:path');
  #|     const base = path.isAbsolute(library) ? library : path.resolve(path.dirname(source), library);
  #|     const dir = path.join(base, 'steamapps');
  #|     const files = fs.readdirSync(dir, {withFileTypes: true})
  #|       .filter(f => f.isFile() && /^appmanifest_[0-9]+\.acf$/.test(f.name))
  #|       .map(f => path.join(dir, f.name)).sort();
  #|     if (files.length > 100000) throw new Error('Too many manifests in library');
  #|     return ['', ...files];
  #|   } catch (e) { return [e.message || 'Unable to list library']; }
  #| }

///|
extern "js" fn host_exit_code(code : Int) -> Unit =
  #| function(code) { process.exitCode = code; }

///|
fn cli_args() -> Array[String] {
  @env.args()
}

///|
fn host_read(path : String) -> FixedArray[String] {
  if path.contains("\u0000") || @utf8.encode(path[:]).length() > 32767 {
    return ["", "Invalid file path"]
  }
  host_read_impl(path)
}

///|
fn host_finish() -> Unit {
  ()
}
