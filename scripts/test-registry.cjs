// Run an independent consumer with only a registry dependency, outside this checkout.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),assert=require('node:assert/strict'),{spawnSync}=require('node:child_process');
const root=path.resolve(__dirname,'..'),version=process.argv[2]||process.env.MOONVALVE_REGISTRY_VERSION||/^version\s*=\s*"([^"]+)"/m.exec(fs.readFileSync(path.join(root,'moon.mod'),'utf8'))[1];
assert.match(version,/^\d+\.\d+\.\d+$/);const temporary=fs.mkdtempSync(path.join(os.tmpdir(),'moonvalve-registry-'));
fs.mkdirSync(path.join(temporary,'cmd/main'),{recursive:true});
fs.writeFileSync(path.join(temporary,'moon.mod'),`name = "integration/registry-consumer"\nversion = "0.0.0"\nlicense = "MIT"\nimport { "Charles67676767/moonvalve@${version}", }\n`);
fs.writeFileSync(path.join(temporary,'cmd/main/moon.pkg'),'import { "Charles67676767/moonvalve" @valve, "moonbitlang/core/json", }\npkgtype(kind: "executable")\n');
const newFeatures=Number(version.split('.')[1])>=5?String.raw`
  let preserved = @valve.parse_kv3_preserving("//keep\n{name='Moon' arr=[1,2,]}", allow_headerless=true)
  let local = preserved.edit(["name"], @valve.KV3Replace(@valve.KV3String("Sun")))
  assert_eq(local.text(), "//keep\n{name=\"Sun\" arr=[1,2,]}")
  let appended = local.edit(["arr"], @valve.KV3InsertElement(2, @valve.KV3Null))
  assert_true(appended.text().contains("null"))
  let batch = @valve.new_workspace({"a":"r {path old/a}","b":"r {path old/b}"})
  assert_true(batch.select("/**/path").stringify().contains("old/b"))
  let changed = batch.edit_query("/**/path", @valve.ReplacePrefix("old/", "new/"), files=["a"])
  assert_eq(changed.files()["a"], "r {path new/a}")
  assert_eq(changed.files()["b"], "r {path old/b}")
  server.handle(Json::object({"jsonrpc":Json::string("2.0"),"method":Json::string("moonvalve/setFile"),"params":Json::object({"uri":Json::string("file:///project/main.vdf"),"text":Json::string("#base base.vdf\nr {}")})})) |> ignore
  let rename = server.handle(Json::object({"jsonrpc":Json::string("2.0"),"id":Json::number(2),"method":Json::string("workspace/willRenameFiles"),"params":Json::object({"files":Json::array([Json::object({"oldUri":Json::string("file:///project/base.vdf"),"newUri":Json::string("file:///project/new.vdf")})])})}))
  assert_true(rename[0].stringify().contains("new.vdf"))
`:'';
fs.writeFileSync(path.join(temporary,'cmd/main/main.mbt'),`///|
fn verify() -> Unit raise {
  assert_eq(@valve.version(), "${version}")
  let doc = @valve.parse("r { n 9007199254740993 tag one tag two }")
  assert_eq(doc.read_int64([{key:"r",occurrence:0},{key:"n",occurrence:0}]), 9007199254740993L)
  assert_eq(doc.select("/**/tag").length(), 2)
  let source = @valve.parse_preserving("// keep\\nr { tag one tag two target {} }")
  let edited = source.edit_query("/**/tag", @valve.SetText("Moon"))
  assert_eq(edited.document().select("/**/tag?==\\\"Moon\\\"").length(), 2)
  let copied = source.transfer([{key:"r",occurrence:0},{key:"tag",occurrence:1}], [{key:"r",occurrence:0},{key:"target",occurrence:0}], 0, copy=true)
  assert_eq(copied.document().lookup(["r","target","tag"]), Some(@valve.Text("two")))
  let kv3 = @valve.parse_kv3("{id=18446744073709551615 flag=resource:\\\"moon\\\" arr=[true,null]}", allow_headerless=true)
  let model = @valve.kv3_to_json(kv3)
  assert_eq(@valve.kv3_to_json(@valve.kv3_from_json(model)), model)
  assert_true(@valve.stringify_kv3(kv3).contains("18446744073709551615"))
  let files : Map[String, String] = {"main":"#base base\\nr {}", "base":"r {key value}"}
  let moved = @valve.new_workspace(files).rename_file("base", "config/base").files()
  assert_true(moved.get("main").unwrap().contains("config/base"))
  let server = @valve.new_lsp_server()
  let initialized = server.handle(@json.parse("{\\\"jsonrpc\\\":\\\"2.0\\\",\\\"id\\\":1,\\\"method\\\":\\\"initialize\\\",\\\"params\\\":{}}"))
  assert_eq(initialized.length(), 1)
  ${newFeatures}
  println("Registry ${version}: parsing, exact integers, queries, source edits, transfer, KV3, workspace and LSP passed")
}
///|
fn main { verify() catch { error => abort(error.to_string()) } }
`);
const passed=[];
function moon(args){const r=spawnSync('moon',['-C',temporary,...args],{cwd:temporary,encoding:'utf8',timeout:180000,maxBuffer:8*1024*1024});if(r.error)throw r.error;assert.equal(r.status,0,r.stderr+'\n'+r.stdout);process.stdout.write(r.stdout);}
try{
  assert.ok(!fs.existsSync(path.join(temporary,'moon.work')));moon(['update']);moon(['check','--target','all','--deny-warn']);
  const installed=path.join(temporary,'.mooncakes/Charles67676767/moonvalve/moon.mod');assert.ok(fs.existsSync(installed),'The registry dependency must be downloaded');
  assert.ok(!fs.realpathSync(installed).startsWith(root+path.sep),'Consumer must not resolve the checkout');
  assert.match(fs.readFileSync(installed,'utf8'),new RegExp('version\\s*=\\s*"'+version.replace(/\./g,'\\.')+'"'));
  for(const target of ['wasm','wasm-gc','js','native']){moon(['run','cmd/main','--target',target]);passed.push(target);}
  fs.mkdirSync(path.join(root,'_build'),{recursive:true});fs.writeFileSync(path.join(root,`_build/registry-check-${version}.json`),JSON.stringify({module:'Charles67676767/moonvalve',version,registry_only:true,targets:passed,features:['parse','int64','query','source-edit','transfer','kv3','workspace','lsp',...(newFeatures?['kv3-preserving','workspace-fields','lsp-file-rename']:[])]},null,2)+'\n');
  console.log('Independent registry installation verified on all four backends');
}finally{const resolved=fs.realpathSync(temporary),parent=fs.realpathSync(os.tmpdir());assert.ok(resolved.startsWith(parent+path.sep)&&path.basename(resolved).startsWith('moonvalve-registry-'));fs.rmSync(resolved,{recursive:true,force:true});}
