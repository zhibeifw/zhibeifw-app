import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {parseAppNotice} from '../core.mjs';

const {cases} = JSON.parse(readFileSync(new URL('../../doc/test-vectors/app-notice.json', import.meta.url)));

test('公告配置、正文与可选外链', () => {
  for (const [name, raw, message, label, url, dismissalKey] of cases) {
    const data = (() => { try { return JSON.parse(raw); } catch { return null; } })();
    assert.deepEqual(parseAppNotice(data), message === null ? null : {dismissalKey, message, link: label === null ? null : {label, url}}, name);
  }
  assert.equal(parseAppNotice({enabled:true, message:'课'.repeat(181)}), null);
});

test('公告只向已选线路读取，缺失或超限时隐藏', async t => {
  const calls = [];
  let announcement = () => Response.json({enabled:true, message:'年度共修开放报名'});
  t.mock.method(globalThis, 'fetch', async url => {
    calls.push(url);
    if (url === 'https://zbfw.org/domains.json') throw Error('主线路不可用');
    if (url === 'https://zbfw.app/domains.json') return Response.json({domains:['https://zbfw.app']});
    return announcement();
  });
  const {loadAppNotice} = await import('../network.mjs');
  assert.equal((await loadAppNotice()).message, '年度共修开放报名');
  assert.deepEqual(calls, ['https://zbfw.org/domains.json', 'https://zbfw.app/domains.json', 'https://zbfw.app/app-notice.json']);
  announcement = () => new Response('不存在', {status:404});
  assert.equal(await loadAppNotice(), null);
  announcement = () => Response.json({enabled:true, message:'课', padding:'x'.repeat(4096)});
  assert.equal(await loadAppNotice(), null);
  assert.deepEqual(calls.slice(3), Array(2).fill('https://zbfw.app/app-notice.json'));
});
