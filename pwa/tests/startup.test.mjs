import test from 'node:test';
import assert from 'node:assert/strict';

test('冷启动先读取本地目录，线路不可用时保留目录且不进入首次加载', async t => {
  const saved = {
    origin: 'https://zbfw.org',
    etag: '"saved"',
    raw: {categories: [{id: 'cached', name: '已缓存的分类'}]},
  };
  const complete = result => {
    const request = {result};
    queueMicrotask(() => request.onsuccess());
    return request;
  };
  Object.defineProperty(globalThis, 'indexedDB', {
    configurable: true,
    value: {open: (name, version) => {
      assert.equal(name, 'zhibeifw.db');
      assert.equal(version, 1);
      return complete({transaction: () => {
        const transaction = {objectStore: () => ({get: key => ({result: key === 'current' ? saved : undefined})})};
        queueMicrotask(() => transaction.oncomplete());
        return transaction;
      }});
    }},
  });
  t.after(() => delete globalThis.indexedDB);
  const request = t.mock.method(globalThis, 'fetch', async () => { throw Error('线路不可用'); });
  const {restoreCatalog, loadCatalog} = await import('../network.mjs');
  const catalog = await restoreCatalog();
  assert.equal(catalog.categories[0].name, '已缓存的分类');
  assert.equal(request.mock.callCount(), 0);

  const firstLoad = t.mock.fn();
  const result = await loadCatalog(false, false, firstLoad);
  assert.equal(result.catalog, catalog);
  assert.equal(result.stale, true);
  assert.ok(request.mock.callCount() > 0);
  assert.equal(firstLoad.mock.callCount(), 0);
});

test('本地数据库打开失败和保存中止后能重新读写', async t => {
  let opens = 0;
  let writes = 0;
  let stored;
  const db = {
    transaction: () => {
      const transaction = {objectStore: () => ({
        get: () => {
          queueMicrotask(() => transaction.oncomplete());
          return {result: stored};
        },
        put: (value, key) => {
          const abort = ++writes === 1;
          queueMicrotask(() => {
            if (abort) { transaction.onabort(); return; }
            stored = value;
            transaction.oncomplete();
          });
          return {result: key};
        },
      })};
      return transaction;
    },
  };
  Object.defineProperty(globalThis, 'indexedDB', {
    configurable: true,
    value: {open: () => {
      const request = {result: db, error: new DOMException('数据库暂不可用', 'UnknownError')};
      const fail = ++opens === 1;
      queueMicrotask(() => fail ? request.onerror() : request.onsuccess());
      return request;
    }},
  });
  t.after(() => delete globalThis.indexedDB);
  const {cachedCatalog, cacheCatalog} = await import('../storage.mjs?retry');
  assert.equal(await cachedCatalog(), undefined);
  assert.equal(opens, 2);
  const record = {origin: 'https://zbfw.org', raw: {categories: []}};
  assert.equal(await cacheCatalog(record), true);
  assert.equal(writes, 2);
  assert.equal(await cachedCatalog(), record);
});
