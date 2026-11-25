import assert from 'node:assert/strict';
import test from 'node:test';
import {readRecords, writeRecord} from '../storage.mjs';

test('读取旧预览的记录，多个页面分别更新不同集与收藏时保留各自改动', t => {
 const data = new Map();
 globalThis.localStorage = {
  get length() {return data.size;},
  key: i => [...data.keys()][i],
  getItem: key => data.get(key) ?? null,
  setItem: (key,value) => data.set(key,value)
 };
 t.after(() => delete globalThis.localStorage);
 data.set('zbfw.pwa.favorites', JSON.stringify(['a']));
 data.set('zbfw.pwa.progress', JSON.stringify([['a', {position: 10}]]));
 assert.equal(readRecords('progress').get('a').position,10);
 assert.ok(readRecords('favorites').get('a'));
 writeRecord('favorites','b',true);
 writeRecord('favorites','a',false);
 writeRecord('progress','b',{position: 20});
 writeRecord('progress','a',{position: 15});
 assert.deepEqual([...readRecords('favorites').keys()],['b']);
 assert.deepEqual([...readRecords('progress').values()],[{position:15},{position:20}]);
});
