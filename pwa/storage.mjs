import {validId} from './core.mjs';
const PREFIX='zbfw.pwa.';
export function read(key,fallback){try{return JSON.parse(localStorage.getItem(PREFIX+key))??fallback;}catch{return fallback;}}
export function write(key,value){try{localStorage.setItem(PREFIX+key,JSON.stringify(value));return true;}catch{return false;}}
let dbPromise;
function database(){
 if(dbPromise)return dbPromise;
 const opening=new Promise((resolve,reject)=>{
  const request=indexedDB.open('zhibeifw.db',1);
  request.onupgradeneeded=()=>request.result.createObjectStore('catalog');
  request.onerror=()=>reject(request.error);
  request.onblocked=()=>reject(new DOMException('课程目录数据库正在更新','InvalidStateError'));
  request.onsuccess=()=>{
   const db=request.result;
   if(dbPromise!==opening){db.close();return;}
   const forget=()=>{if(dbPromise===opening)dbPromise=undefined;};
   db.onclose=forget;
   db.onversionchange=()=>{forget();db.close();};
   resolve(db);
  };
 });
 dbPromise=opening;
 opening.catch(()=>{if(dbPromise===opening)dbPromise=undefined;});
 return opening;
}

async function catalogTransaction(mode, operation) {
 for(let attempt=0;attempt<2;attempt++){
  try{
   if(typeof indexedDB==='undefined')return null;
   const db=await database();
   return await new Promise((resolve,reject)=>{
    const transaction=db.transaction('catalog',mode);
    const request=operation(transaction.objectStore('catalog'));
    transaction.oncomplete=()=>resolve(request.result);
    transaction.onabort=()=>reject(transaction.error ?? new DOMException('课程目录事务已中止','AbortError'));
   });
  }catch(error){
   if(['QuotaExceededError','SecurityError','NotSupportedError'].includes(error?.name))return null;
  }
 }
 return null;
}

export const cachedCatalog=()=>catalogTransaction('readonly',store=>store.get('current'));
export const cacheCatalog=async value=>await catalogTransaction('readwrite',store=>store.put(value,'current'))!==null;

// 旧版按整张表保存。逐条覆盖旧值，两个窗口收听不同集时不会互相覆盖。
export function readRecords(name) {
 const rows = new Map();
 const legacy = read(name, []);
 function apply(id, value) {
  if (!validId(id)) return;
  if (name === 'favorites') {
   if (value) rows.set(id, value);
   else rows.delete(id);
  } else if (Number.isFinite(value?.position) && value.position >= 0) {
   rows.set(id, value);
  }
 }
 if (Array.isArray(legacy)) {
  for (const item of legacy) {
   if (name === 'favorites') apply(item, true);
   else if (Array.isArray(item)) apply(item[0], item[1]);
  }
 }
 const prefix = PREFIX + name + '.';
 try {
  for (let i=0; i<localStorage.length; i++) {
   const key=localStorage.key(i);
   if (key?.startsWith(prefix)) apply(key.slice(prefix.length), read(key.slice(PREFIX.length), null));
  }
 } catch { /* 浏览器禁用存储时仍可在当前页面收听。 */ }
 return rows;
}

export function writeRecord(name, id, value) {
 return write(name + '.' + id, value);
}

export function recordCollection(key) {
 return ['favorites', 'progress'].find(name => key?.startsWith(PREFIX + name + '.') || key === PREFIX + name);
}
