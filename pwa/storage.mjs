import {validId} from './core.mjs';
const PREFIX='zbfw.pwa.';
export function read(key,fallback){try{return JSON.parse(localStorage.getItem(PREFIX+key))??fallback;}catch{return fallback;}}
export function write(key,value){try{localStorage.setItem(PREFIX+key,JSON.stringify(value));return true;}catch{return false;}}
let dbPromise;
function database(){
 return dbPromise??=new Promise((resolve,reject)=>{const r=indexedDB.open('zbfw-pwa',1);r.onupgradeneeded=()=>r.result.createObjectStore('catalog');r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error);});
}
export async function cachedCatalog(){try{const db=await database();return await new Promise((resolve,reject)=>{const r=db.transaction('catalog').objectStore('catalog').get('current');r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error);});}catch{return null;}}
export async function cacheCatalog(value){try{const db=await database();await new Promise((resolve,reject)=>{const tx=db.transaction('catalog','readwrite');tx.objectStore('catalog').put(value,'current');tx.oncomplete=resolve;tx.onerror=()=>reject(tx.error);});}catch{/* 目录缓存不可用时仍可在线播放。 */}}

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
