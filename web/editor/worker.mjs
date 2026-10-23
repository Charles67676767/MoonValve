import {dispatch} from './moonvalve.mjs';
self.onmessage=({data:{id,request}})=>{
  try {self.postMessage({id,response:JSON.parse(dispatch(JSON.stringify(request)))});}
  catch(error){self.postMessage({id,response:{ok:false,error:{code:'worker_error',message:error.message}}});}
};
