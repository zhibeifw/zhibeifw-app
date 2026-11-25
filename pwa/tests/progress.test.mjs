import test from 'node:test';
import assert from 'node:assert/strict';
import { manualCompletion, playbackProgress } from '../core.mjs';

const partial = {position: 42, duration: 100, completed: false, modified: 10, hidden: false};

test('手动标记归零，保留最近次序和隐藏状态', () => {
  const done = manualCompletion(partial, 100, true);
  assert.deepEqual(done, {...partial, position: 0, completed: true});
  assert.equal(manualCompletion(undefined, 100, true).hidden, true);
  assert.equal(manualCompletion({...done, hidden: true}, 100, false).hidden, true);
});

test('听完从头重播；清空最近后，定期保存不会恢复隐藏的记录', () => {
  const done = playbackProgress(partial, 70, 100, 20);
  assert.deepEqual(done, {...partial, position: 0, completed: true, modified: 20});
  assert.equal(playbackProgress({...done, hidden: true}, 75, 100, 25).hidden, true);
  assert.equal(playbackProgress({...done, completed: false}, 12, 100, 30).position, 12);
});
