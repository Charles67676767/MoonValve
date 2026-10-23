const http=require('node:http'),fs=require('node:fs'),path=require('node:path');
const root=fs.realpathSync(path.join(__dirname,'../web/editor'));
const port=Number(process.env.MOONVALVE_PORT||8765);
if(!Number.isInteger(port)||port<1024||port>65535)throw new Error('Invalid MOONVALVE_PORT');
http.createServer((request,response)=>{
  try{
    if(!['GET','HEAD'].includes(request.method)){response.writeHead(405);return response.end();}
    const pathname=decodeURIComponent(new URL(request.url,'http://localhost').pathname);
    const file=fs.realpathSync(path.join(root,pathname==='/'?'index.html':pathname));
    if(!file.startsWith(root+path.sep)||!fs.statSync(file).isFile()){response.writeHead(403);return response.end();}
    const type={'.html':'text/html; charset=utf-8','.css':'text/css; charset=utf-8','.mjs':'text/javascript; charset=utf-8'}[path.extname(file)]||'application/octet-stream';
    response.writeHead(200,{'Content-Type':type,'X-Content-Type-Options':'nosniff','Cache-Control':'no-store'});
    if(request.method==='HEAD')return response.end();
    fs.createReadStream(file).pipe(response);
  }catch{response.writeHead(404);response.end('Not found');}
}).listen(port,'127.0.0.1',()=>console.log(`MoonValve local editor: http://127.0.0.1:${port}`));
