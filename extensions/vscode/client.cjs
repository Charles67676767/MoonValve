const {EventEmitter}=require('node:events');

// Transport only. Parsing and language features run in the MoonBit server.
class RpcClient extends EventEmitter {
  constructor(child) {
    super();this.child=child;this.pending=new Map();this.sequence=0;this.buffer=Buffer.alloc(0);
    child.stdout.on('data',chunk=>{try{this.feed(chunk);}catch(error){this.fail(error);child.kill();}});
    child.on('error',error=>this.fail(error));
    child.stdin.on('error',error=>this.fail(error));
    child.stdin.on('error',error=>this.fail(error));
    child.on('exit',(code,signal)=>{this.fail(new Error('MoonValve server exited: '+(signal||code)));this.emit('closed',code);});
  }
  feed(chunk) {
    if(this.buffer.length+chunk.length>16*1024*1024+65536+4096)throw new Error('LSP receive buffer exceeds limit');
    this.buffer=Buffer.concat([this.buffer,chunk]);
    for(;;) {
      const end=this.buffer.indexOf('\r\n\r\n');
      if(end<0){if(this.buffer.length>4096)throw new Error('LSP header exceeds limit');return;}
      if(end>4096)throw new Error('LSP header exceeds limit');
      const lengths=this.buffer.subarray(0,end).toString('ascii').split('\r\n').filter(line=>/^Content-Length:/i.test(line));
      if(lengths.length!==1||!/^Content-Length:\s*[0-9]+\s*$/i.test(lengths[0]))throw new Error('Invalid Content-Length');
      const length=Number(lengths[0].split(':')[1].trim());
      if(length<1||length>16*1024*1024)throw new Error('LSP message exceeds limit');
      if(this.buffer.length<end+4+length)return;
      const body=this.buffer.subarray(end+4,end+4+length);
      const message=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(body));
      this.buffer=this.buffer.subarray(end+4+length);
      const item=this.pending.get(message.id);
      if(item&&('result'in message||'error'in message)){
        this.pending.delete(message.id);clearTimeout(item.timeout);
        if(message.error){const error=new Error(message.error.message);error.rpcCode=message.error.code;item.reject(error);}else item.resolve(message.result);
      }else this.emit('notification',message);
    }
  }
  send(message) {
    const body=Buffer.from(JSON.stringify(message)),frame=Buffer.concat([Buffer.from('Content-Length: '+body.length+'\r\n\r\n'),body]);
    if(body.length>16*1024*1024||this.child.stdin.writableLength+frame.length>32*1024*1024)throw new Error('LSP send budget exceeded');
    if(this.child.stdin.destroyed)throw new Error('Server input is closed');
    this.child.stdin.write(frame);
  }
  request(method,params={}) {
    const id=++this.sequence;
    return new Promise((resolve,reject)=>{
      const timeout=setTimeout(()=>{this.pending.delete(id);reject(new Error('LSP request timed out: '+method));},15000);
      this.pending.set(id,{resolve,reject,timeout});
      try{this.send({jsonrpc:'2.0',id,method,params});}catch(error){this.pending.delete(id);clearTimeout(timeout);reject(error);}
    });
  }
  notify(method,params={}){this.send({jsonrpc:'2.0',method,params});}
  fail(error){for(const item of this.pending.values()){clearTimeout(item.timeout);item.reject(error);}this.pending.clear();}
  dispose(){this.fail(new Error('Client closed'));this.child.kill();}
}
module.exports={RpcClient};
