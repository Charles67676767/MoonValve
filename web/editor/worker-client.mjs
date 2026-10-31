// A failed or timed-out worker cannot deliver stale results to its replacement.
export function createCoreClient(factory,{timeoutMs=30000}={}) {
  let worker=null,sequence=0;
  const pending=new Map();
  function reset(message){const previous=worker;worker=null;previous?.terminate();for(const p of pending.values()){clearTimeout(p.timer);p.reject({code:'worker_unavailable',message});}pending.clear();}
  function start(){if(worker)return;const current=factory();worker=current;
    current.onmessage=({data})=>{if(worker!==current)return;const p=pending.get(data.id);if(!p)return;pending.delete(data.id);clearTimeout(p.timer);data.response.ok?p.resolve(data.response.result):p.reject(data.response.error);};
    current.onerror=()=>{if(worker===current)reset('解析器异常，当前操作已取消。原文件未修改；请重试，或使用命令行处理。');};
    current.onmessageerror=()=>{if(worker===current)reset('解析器返回了无法读取的数据，请重新操作。');};
  }
  return {request(request){return new Promise((resolve,reject)=>{try{start();const id=++sequence;const timer=setTimeout(()=>reset('处理超过30秒，已停止解析器。原文件未修改；请检查文件或使用命令行。'),timeoutMs);pending.set(id,{resolve,reject,timer});worker.postMessage({id,request},request.buffer?[request.buffer]:[]);}catch(e){reset('解析器未能启动，请确认工作台已完整解压。');reject(e);}});},dispose(){reset('操作已取消。');}};
}
