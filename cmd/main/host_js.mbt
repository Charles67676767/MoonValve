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
extern "js" fn host_output_impl(text : String) -> String =
  #| function(text) { try { const fs=require('node:fs'),bytes=Buffer.from(text); let offset=0; while(offset<bytes.length){try{const n=fs.writeSync(1,bytes,offset,bytes.length-offset);if(!n)throw new Error('Output closed');offset+=n;}catch(e){if(e.code!=='EAGAIN'&&e.code!=='EWOULDBLOCK')throw e;Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,5);}}return ''; }catch(e){return e.message||'Output failed';} }

///|
let output_failure : Ref[String] = { val: "", }

///|
fn host_output(text : String) -> Unit {
  let error = host_output_impl(text)
  if error != "" {
    output_failure.val = error
    host_exit_code(2)
  }
}

///|
extern "js" fn host_stream_open_impl(path : String) -> Int =
  #| function(path) { try { return path==='-'?0:require('node:fs').openSync(path,'r'); }catch{return -1;} }

///|
extern "js" fn host_stream_chunk_impl(handle : Int) -> FixedArray[Bytes] =
  #| function(handle) { try{ const bytes=Buffer.alloc(65536),n=require('node:fs').readSync(handle,bytes,0,bytes.length,null); return [bytes.subarray(0,n),new Uint8Array()]; }catch(e){return [new Uint8Array(),Buffer.from(e.message||'Read failed')];} }

///|
fn host_stream_chunk(handle : Int) -> Bytes raise CliError {
  let result = host_stream_chunk_impl(handle)
  if !result[1].is_empty() {
    raise InvalidArgument(@utf8.decode_lossy(result[1][:]))
  }
  result[0]
}

///|
extern "js" fn host_stream_close(handle : Int) -> Unit =
  #| function(handle) { if(handle!==0)require('node:fs').closeSync(handle); }

///|
fn host_stream_open(path : String) -> Int raise CliError {
  if path.contains("\u0000") || @utf8.encode(path[:]).length() > 32767 {
    raise InvalidArgument("Invalid stream path")
  }
  let result = host_stream_open_impl(path)
  if result < 0 {
    raise InvalidArgument("Unable to open stream")
  }
  result
}

///|
fn host_output_check() -> Unit raise CliError {
  if output_failure.val != "" {
    raise InvalidArgument(output_failure.val)
  }
}

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

///|
extern "js" fn host_bytes_impl(path : String, limit : Int) -> FixedArray[Bytes] =
  #| function(path, limit) {
  #|   const fs = require('node:fs'); let fd;
  #|   try {
  #|     fd = path === '-' ? 0 : fs.openSync(path, 'r');
  #|     const chunks = []; let length = 0;
  #|     for (;;) {
  #|       const chunk = Buffer.alloc(65536), n = fs.readSync(fd, chunk, 0, chunk.length, null);
  #|       if (!n) break;
  #|       length += n; if (length > limit) throw new Error('Input exceeds byte limit');
  #|       chunks.push(chunk.subarray(0,n));
  #|     }
  #|     return [Buffer.concat(chunks), new Uint8Array()];
  #|   } catch(e) { return [new Uint8Array(), Buffer.from(e.message || 'Read failed')]; }
  #|   finally { if (fd !== undefined && fd !== 0) fs.closeSync(fd); }
  #| }

///|
fn host_read_bytes(
  path : String,
  limit? : Int = 16777216,
) -> Bytes raise CliError {
  if path.contains("\u0000") || @utf8.encode(path[:]).length() > 32767 {
    raise InvalidArgument("Invalid file path")
  }
  let result = host_bytes_impl(path, limit)
  if !result[1].is_empty() {
    raise InvalidArgument(@utf8.decode_lossy(result[1][:]))
  }
  result[0]
}

///|
extern "js" fn host_output_bytes_impl(bytes : Bytes) -> String =
  #| function(bytes) { try{const fs=require('node:fs');let offset=0;while(offset<bytes.length){try{const n=fs.writeSync(1,bytes,offset,bytes.length-offset);if(!n)throw new Error('Output closed');offset+=n;}catch(e){if(e.code!=='EAGAIN'&&e.code!=='EWOULDBLOCK')throw e;Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,5);}}return '';}catch(e){return e.message||'Output failed';} }

///|
fn host_output_bytes(bytes : Bytes) -> Unit {
  let error = host_output_bytes_impl(bytes)
  if error != "" {
    output_failure.val = error
    host_exit_code(2)
  }
}

///|
extern "js" fn host_confined_impl(
  root : String,
  relative : String,
) -> FixedArray[String] =
  #| function(root, relative) {
  #|   try {
  #|     const fs=require('node:fs'), path=require('node:path');
  #|     const base=fs.realpathSync(root), target=fs.realpathSync(path.join(base,relative));
  #|     if (!fs.statSync(base).isDirectory()) throw new Error('Root must be a directory');
  #|     const rel=path.relative(base,target);
  #|     if (rel==='..' || rel.startsWith('..'+path.sep) || path.isAbsolute(rel)) throw new Error('Reference escapes the chosen root');
  #|     return [target,''];
  #|   } catch(e) {return ['',e.message || 'Cannot resolve reference'];}
  #| }

///|
fn host_confined(root : String, relative : String) -> String raise CliError {
  validate_reference_path(root, relative)
  let result = host_confined_impl(root, relative)
  if result[1] != "" {
    raise InvalidArgument(result[1])
  }
  result[0]
}

///|
extern "js" fn host_save_impl(
  path : String,
  before : Bytes,
  after : Bytes,
) -> String =
  #| function(target,before,after) {
  #|   const fs=require('node:fs'), crypto=require('node:crypto'); let temporary,backupCreated=false;
  #|   const backup=target+'.bak';
  #|   try {
  #|     const stat=fs.lstatSync(target); if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('Target must be a regular file');
  #|     if (!fs.readFileSync(target).equals(Buffer.from(before))) throw new Error('Input changed since it was read');
  #|     temporary=target+'.moonvalve-'+crypto.randomBytes(8).toString('hex');
  #|     const fd=fs.openSync(temporary,'wx',stat.mode);
  #|     try {fs.writeFileSync(fd,Buffer.from(after));fs.fchmodSync(fd,stat.mode);fs.fsyncSync(fd);} finally {fs.closeSync(fd);}
  #|     const backupFd=fs.openSync(backup,'wx',stat.mode); backupCreated=true;
  #|     try {fs.writeFileSync(backupFd,Buffer.from(before));fs.fsyncSync(backupFd);} finally {fs.closeSync(backupFd);}
  #|     if (!fs.readFileSync(target).equals(Buffer.from(before))) throw new Error('Input changed before replacement');
  #|     fs.renameSync(temporary,target); temporary=undefined; return '';
  #|   } catch(e) {return e.message || 'Save failed';}
  #|   finally {if(temporary) {try{fs.unlinkSync(temporary);}catch{}}}
  #| }

///|
fn host_save(
  path : String,
  before : Bytes,
  after : Bytes,
) -> Unit raise CliError {
  if path == "-" || path.contains("\u0000") {
    raise InvalidArgument("Saving requires a file path")
  }
  let error = host_save_impl(path, before, after)
  if error != "" {
    raise InvalidArgument(error)
  }
}
