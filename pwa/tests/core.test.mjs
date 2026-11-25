import test from 'node:test';
import assert from 'node:assert/strict';
import {validId, validPath, parseCatalog, completed, limitSearchText, searchCourses, mediaURL, coverSourcePath} from '../core.mjs';
test('按物理像素选择封面，保留原始版本号', () => {
 const path = '课程.v1/cover-2.jpg';
 for (const pixels of [96, 320]) assert.equal(coverSourcePath(path, pixels), '课程.v1/cover-2-320.jpg');
 for (const pixels of [321, 640]) assert.equal(coverSourcePath(path, pixels), '课程.v1/cover-2-640.jpg');
 assert.equal(coverSourcePath(path, 641), path);
 assert.equal(coverSourcePath('课程.v1/cover', 320), '课程.v1/cover');
});
test('reject untrusted IDs and resource paths', () => {
  assert.ok(validId('入中论_01')); assert.ok(!validId('<script>'));
  for(const p of ['../a','https://evil/a','//evil/a','a\\b','a?b','/a','a b','a%2f..%2fb']) assert.ok(!validPath(p), p);
  assert.equal(mediaURL('https://zbfw.org','基础/课/第1集.m4a'),'https://zbfw.org/%E5%9F%BA%E7%A1%80/%E8%AF%BE/%E7%AC%AC1%E9%9B%86.m4a');
});
test('catalog rejects bad rows and duplicate IDs, keeps series order', () => {
  const s = {id:'课', title:'课程', coverPath:'课/cover.jpg',status:'ongoing',episodes:[{id:'课_1',title:'第一集',audioPath:'课/1.mp3'},{id:'课_1',title:'重复',audioPath:'课/2.mp3'},{id:'课_2',title:'注入',audioPath:'https://evil'}]};
  const c = parseCatalog({categories:[{id:'分类',name:'分类',series:[s,s]}],featured:[{title:'推荐',seriesId:'课'}]});
  assert.equal(c.series.length,1);assert.equal(c.series[0].episodes.length,1);
  assert.throws(()=>parseCatalog({categories:[]}));
});
test('completion matches long and short episode thresholds',()=>{
 assert.equal(completed(69,100),false);assert.equal(completed(70,100),true);
 assert.equal(completed(18,20),false);assert.equal(completed(19,20),true);assert.equal(completed(0,0),false);
});
test('search exact phrase then longest prefix',()=>{
 const courses=[{title:'入中论讲解'},{title:'入行论讲解'}];
 assert.equal(searchCourses(courses,'入中论')[0].length,1);
 assert.deepEqual(searchCourses(courses,'入中论某课'),[[courses[0]],'入中论']);
 assert.equal(searchCourses(courses,'不存在')[0].length,0);
});

test('使用共用的 ID、路径和线路用例；拒绝无法编码为 URL 的路径', async () => {
 const {readFile} = await import('node:fs/promises');
 const {validOrigin} = await import('../core.mjs');
 for (const [name, validate] of [['ids',validId],['paths',validPath],['origins',validOrigin]]) {
  const vectors=JSON.parse(await readFile(new URL('../../doc/test-vectors/'+name+'.json',import.meta.url)));
  for(const value of vectors.valid) assert.ok(validate(value), String(value));
  for(const value of vectors.invalid) assert.ok(!validate(value), String(value));
 }
 assert.equal(validPath('课/\uD800.mp3'),false);
});

test('搜索统一全角、大小写与空白，按完整字符回退', () => {
 const course={title:'ＡＢＣ 入 行论'};
 assert.deepEqual(searchCourses([course],'  abc\u200B 入  行论 之外'),[[course],'abc 入 行论']);
 assert.deepEqual(searchCourses([{title:'𠀁'}],'𠀀')[0],[]);
});

test('新课程只展示最近更新的十门在更课程，同一时间按目录先后', async () => {
 const {newCourses} = await import('../core.mjs');
 const series = Array.from({length:12}, (_,id)=>({id,status:'ongoing',updatedAt:id===10?5:0}));
 series.push({id:12,status:'completed',updatedAt:20});
 assert.deepEqual(newCourses(series).map(s=>s.id),[10,0,1,2,3,4,5,6,7,8]);
});

test('课程名开头优先，多字查询不能退到单字，单字本身仍能搜索', () => {
 const courses = [{title:'读入中论'}, {title:'入中论'}];
 assert.deepEqual(searchCourses(courses, '入中')[0], [courses[1], courses[0]]);
 assert.deepEqual(searchCourses(courses, '入门')[0], []);
 assert.equal(searchCourses(courses, '入')[0].length, 2);
});

test('异常更新时间不影响课程保留与首页排序', () => {
 const bad = [-1, 1.5, 1e11];
 const series = bad.map((updatedAt, i) => ({id:'s'+i, title:'测试', coverPath:'c.jpg', status:'ongoing', updatedAt}));
 const catalog = parseCatalog({categories:[{id:'a',name:'分类',series}]});
 assert.deepEqual(catalog.series.map(course => course.updatedAt), [0,0,0]);
});

test('最近播放过滤隐藏记录后取最新 500 集，重听可回到首位', async () => {
 const {recentEntries} = await import('../core.mjs');
 const progress = new Map(Array.from({length:502}, (_,i)=>[String(i), {modified:i, hidden:i===501}]));
 const recent = recentEntries(progress);
 assert.equal(recent.length,500);
 assert.equal(recent[0][0],'500');
 assert.equal(recent.at(-1)[0],'1');
 assert.equal(progress.size,502);
 progress.get('0').modified=502;
 assert.equal(recentEntries(progress)[0][0],'0');
});

test('搜索框粘贴最多保留 30 个字符，完整保留扩展汉字', () => {
 const first='𠀀'.repeat(30);
 assert.equal(limitSearchText(first+'甲'),first);
 assert.deepEqual(searchCourses([{title:first}],first+'甲')[1],first);
});
