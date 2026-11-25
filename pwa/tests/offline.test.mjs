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

test('封面缓存按相对路径跨线路复用，清除后重新请求，跳过失败和非图片响应', async () => {
 const scope = 'https://example.test/listen/';
 const handlers = new Map();
 const coverCache = new Map();
 const requests = [];
 let offline = false;
 const cache = {
  match: async key => coverCache.get(key),
  put: async (key, response) => { coverCache.set(key, response); },
 };
 const self = {registration:{scope},addEventListener:(name,fn)=>handlers.set(name,fn)};
 const caches = {open: async name => {
  assert.equal(name, 'zbfw-covers:' + scope);
  return cache;
 }};
 const fetch = async (request, options) => {
  requests.push([request.url, options?.cache]);
  if (offline) throw Error('offline');
  if (request.url.includes('/legacy-') && request.url.endsWith('-320.jpg')) return new Response('', {status: 404});
  if (request.url.endsWith('/missing.jpg')) return new Response('缺少封面', {status: 404});
  if (request.url.endsWith('/wrong.jpg')) return new Response('not an image');
  return new Response(request.url, {headers:{'Content-Type':'image/jpeg'}});
 };
 const code = await readFile(new URL('../sw.js', import.meta.url), 'utf8');
 vm.runInNewContext(code, {self, URL, Request, Response, caches, fetch});
 async function request(url, destination='image', mode='cors', clientId='tab') {
  let result;
  const work = [];
  handlers.get('fetch')({request:{url, method:'GET', destination, mode}, clientId,
   respondWith: value => { result = value; }, waitUntil: value => work.push(value)});
  const response = await result;
  await Promise.all(work);
  return response;
 }
 const first = 'https://zbfw.org/course/cover.jpg';
 const mirror = 'https://zbfw.app/course/cover.jpg';
 assert.equal(await (await request(first)).text(), first);
 offline = true;
 assert.equal(await (await request(mirror)).text(), first);
 assert.deepEqual(requests, [[first, 'reload']]);
 assert.equal((await request('https://zbfw.app/uncached.jpg')).type, 'error');

 coverCache.clear();
 offline = false;
 assert.equal(await (await request(mirror)).text(), mirror);
 assert.equal((await request('https://zbfw.app/missing.jpg')).status, 404);
 assert.equal((await request('https://zbfw.app/wrong.jpg')).status, 200);
 assert.equal(coverCache.size, 1);
 assert.equal(await request('https://zbfw.app/audio.m4a', 'audio'), undefined);
 assert.equal(await request('https://zbfw.app/cover.jpg', 'image', 'no-cors'), undefined);

 const thumbnail = 'https://zbfw.org/course/cover-320.jpg';
 assert.equal(await (await request(thumbnail + '?zbfw-cover')).text(), thumbnail);
 offline = true;
 assert.equal(await (await request(thumbnail.replace('zbfw.org', 'zbfw.app') + '?zbfw-cover')).text(), thumbnail);
 assert.equal(await (await request(mirror.replace('.jpg', '-640.jpg') + '?zbfw-cover')).text(), mirror);
 offline = false;

 for (let index = 0; index <= 3; index++) {
  const original = `https://zbfw.org/legacy-${index}.jpg`;
  const small = original.replace('.jpg', '-320.jpg');
  const before = requests.length;
  assert.equal(await (await request(small + '?zbfw-cover', 'image', 'cors', 'legacy-tab')).text(), original);
  assert.deepEqual(requests.slice(before).map(([url]) => url), index < 3 ? [small, original] : [original]);
 }
});
