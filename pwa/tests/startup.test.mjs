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
    value: {open: () => complete({
      transaction: () => ({objectStore: () => ({get: key => complete(key === 'current' ? saved : undefined)})}),
    })},
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
