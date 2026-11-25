import test from 'node:test';
import assert from 'node:assert/strict';

test('确定线路后停止探测，304沿用目录，200缺少ETag时丢弃旧值，普通重试沿用当前线路', async t => {
  const values = new Map();
  Object.defineProperty(globalThis, 'localStorage', {configurable: true, value: {
    getItem: k => values.get(k), setItem: (k, v) => values.set(k, v)
  }});
  t.after(() => delete globalThis.localStorage);
  const requests = [];
  let response = () => Response.json({categories: [{id: 'c', name: '课程'}]}, {headers: {ETag: '"one"'}});
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    requests.push([url, new Headers(options.headers)]);
    return url.endsWith('/domains.json') ? Response.json({domains: ['https://zbfw.org']}) : response();
  });
  const {loadCatalog} = await import('../network.mjs');
  assert.equal((await loadCatalog()).stale, false);
  response = () => new Response(null, {status: 304});
  assert.equal((await loadCatalog(true)).catalog.categories[0].id, 'c');
  assert.equal(requests.at(-1)[1].get('If-None-Match'), '"one"');
  response = () => Response.json({categories: [{id: 'd', name: '新课'}]});
  await loadCatalog(true);
  response = () => Response.json({});
  assert.equal((await loadCatalog(true)).stale, true);
  assert.equal(requests.at(-1)[1].has('If-None-Match'), false);
  await new Promise(resolve => setTimeout(resolve, 1600));
  assert.equal(requests.filter(([url]) => url.endsWith('/domains.json')).length, 1);
});

test('手动检测优先保留健康的当前线路，线路结果与目录更新分别判断', async t => {
  const values = new Map([['zbfw.pwa.origin', '"https://zbfw.app"']]);
  Object.defineProperty(globalThis, 'localStorage', {configurable: true, value: {
    getItem: key => values.get(key), setItem: (key, value) => values.set(key, value)
  }});
  t.after(() => delete globalThis.localStorage);
  let offline = false, failIndex = false, blockCurrent = false;
  const probes = [];
  t.mock.method(globalThis, 'fetch', async url => {
    if (url.endsWith('/domains.json')) {
      probes.push(new URL(url).host);
      if (offline || blockCurrent && url.includes('zbfw.app')) throw Error('offline');
      return Response.json({domains: ['https://zbfw.org', 'https://zbfw.app']});
    }
    return failIndex ? new Response(null, {status: 503}) : Response.json({categories: [{id:'c',name:'课程'}]});
  });
  const {loadCatalog, ensureOrigin} = await import('../network.mjs?manual');
  await loadCatalog();
  assert.equal(probes[0], 'zbfw.app');
  assert.equal((await loadCatalog(true, true)).routeResult, '线路正常');
  assert.deepEqual(probes, ['zbfw.app','zbfw.app']);
  blockCurrent = true;
  assert.equal((await loadCatalog(true, true)).routeResult, '已切换到备用线路，连接正常');
  failIndex = true;
  const checked = await loadCatalog(true, true);
  assert.equal(checked.routeResult, '线路正常');
  assert.equal(checked.stale, false);
  offline = true;
  assert.equal((await loadCatalog(true, true)).routeResult, '暂时无法连接');
  assert.equal(JSON.parse(values.get('zbfw.pwa.origin')), null);
  offline = false;
  assert.equal(await ensureOrigin(), 'https://zbfw.org');
});

test('首次目录失败后按同一条线路重试，等待期间报告下一次尝试', async t => {
  const attempts = [], origins = [];
  let probes = 0;
  t.mock.method(globalThis, 'fetch', async url => {
    const address = new URL(url);
    if (address.pathname === '/domains.json') {
      probes++;
      return Response.json({domains: [address.origin]});
    }
    origins.push(address.origin);
    if (origins.length < 3) return new Response(null, {status: 503});
    return Response.json({categories: [{id: 'c', name: '分类'}]});
  });
  const {loadCatalog} = await import('../network.mjs?initial-retry');
  const result = await loadCatalog(false, false, attempt => attempts.push(attempt));
  assert.deepEqual(attempts, [1, 2, 3]);
  assert.equal(probes, 1);
  assert.deepEqual(origins, Array(3).fill('https://zbfw.org'));
  assert.equal(result.catalog.categories[0].name, '分类');
  assert.equal(result.stale, false);
});
