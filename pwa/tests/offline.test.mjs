import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';

test('带查询串与定位的离线导航命中同一目录内的入口；音频交由浏览器处理', async () => {
 const scope='https://example.test/listen/';
 const handlers = new Map();
 const self = {registration:{scope},addEventListener:(name,fn)=>handlers.set(name,fn)};
 const keys=[];
 const cache={match:async key=>{keys.push(key);return 'cached';}};
 const code=await readFile(new URL('../sw.js',import.meta.url),'utf8');
 vm.runInNewContext(code,{self,URL,caches:{open:async()=>cache}});
 async function request(url,mode='navigate'){
  let result;
  handlers.get('fetch')({request:{url,method:'GET',mode},respondWith:value=>{result=value;}});
  return result;
 }
 for(const path of ['?via=app#recent','index.html#favorites','#series/test']) {
  assert.equal(await request(scope+path),'cached');
  assert.equal(keys.at(-1),scope+'index.html');
 }
 assert.equal(await request(scope+'assets/bookmark_24px.svg','no-cors'),'cached');
 assert.equal(await request('https://zbfw.org/audio.m4a','no-cors'),undefined);
 assert.equal(await request(scope+'audio.m4a','no-cors'),undefined);
 assert.equal(await request('https://example.test/'),undefined);
});
