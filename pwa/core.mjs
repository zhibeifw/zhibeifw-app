export const validId = v => typeof v === 'string' && v.length > 0 && v.length <= 100 && v === v.normalize('NFC') && /^[\p{L}\p{Nd}_-]+$/u.test(v);
export const validPath = v => typeof v === 'string' && v.length > 0 && v.length <= 300 && !/[\uD800-\uDFFF]/u.test(v) && !v.startsWith('/') && !v.includes('..') && !v.includes('//') && !/^[a-z][a-z\d+.-]*:/i.test(v) && !/[\\\x00-\x20\x7f?#%]/.test(v);
export const validOrigin = v => {try { const u = new URL(v);return u.protocol === 'https:' && u.origin === v && !u.username && !u.password;}catch{return false;}};
const title = v => typeof v === 'string' && v.trim().length > 0 && v.length <= 200;
export function mediaURL(origin,path) {
 if(!validOrigin(origin) || !validPath(path)) throw Error('无效的资源地址');
 return origin + '/' + path.split('/').map(encodeURIComponent).join('/');
}
export function parseCatalog(raw) {
 if(!Array.isArray(raw?.categories)) throw Error('课程目录格式无效');
 let rawSeries=0;
 const categories=[],series=[],catIds=new Set(),seriesIds=new Set(),episodeIds=new Set();
 for(const c of raw.categories) {
  if(!validId(c?.id)||!title(c.name)||catIds.has(c.id))continue;
  catIds.add(c.id);categories.push({id:c.id,name:c.name,icon:typeof c.icon==='string'?c.icon:'book-outline',color:typeof c.color==='string'?c.color:''});
  for(const s of Array.isArray(c.series)?c.series:[]) {
   rawSeries++;
   if(!validId(s?.id)||seriesIds.has(s.id)||!title(s.title)||!validPath(s.coverPath)||!['ongoing','completed'].includes(s.status))continue;
   seriesIds.add(s.id);
   const episodes=[];
   for(const e of Array.isArray(s.episodes)?s.episodes:[]) {
    if(!validId(e?.id)||episodeIds.has(e.id)||!title(e.title)||!validPath(e.audioPath))continue;
    episodeIds.add(e.id);episodes.push({id:e.id,title:e.title,audioPath:e.audioPath,duration:Number.isFinite(e.duration)&&e.duration>0&&e.duration<=86400?Math.round(e.duration):0});
   }
   series.push({id:s.id,title:s.title,categoryId:c.id,coverPath:s.coverPath,status:s.status,description:typeof s.description==='string'?s.description.slice(0,5000):'',updatedAt:Number.isInteger(s.updatedAt) && s.updatedAt > 0 && s.updatedAt < 1e11 ? s.updatedAt : 0,episodes});
  }
 }
 if(!categories.length||(rawSeries>0&&!series.length))throw Error('课程目录为空');
 const featured=(Array.isArray(raw.featured)?raw.featured:[]).filter(f=>title(f?.title)&&seriesIds.has(f.seriesId)).slice(0,50);
 const categoryOrder=[...new Set((Array.isArray(raw.categoryOrder)?raw.categoryOrder:[]).filter(id=>catIds.has(id)))];
 return {categories,series,featured,categoryOrder};
}
export const completed=(position,duration)=>duration>0&&(duration<=30?position/duration>=.95:duration-position<=30);
export const limitSearchText = value => Array.from(value).slice(0, 30).join('');
export function normalizeQuery(value) {
 return value.replace(/[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u2028-\u202e\u2060-\u2064\ufeff]/gu, '')
   .normalize('NFKC').toLowerCase().trim().replace(/\s+/gu, ' ');
}
export function searchCourses(series, query) {
 const characters = Array.from(normalizeQuery(limitSearchText(query)));
 const full = characters.join('');
 const titles = series.map(course => normalizeQuery(course.title));
 const minimum = Math.min(2, characters.length);
 while (characters.length && characters.length >= minimum) {
  const prefix = characters.join('');
  const hits = series.map((course,index) => ({course,title:titles[index]}))
   .filter(item => item.title.includes(prefix))
   .sort((a,b) => Number(b.title.startsWith(prefix)) - Number(a.title.startsWith(prefix)))
   .slice(0,500).map(item => item.course);
  if (hits.length) return [hits, prefix];
  characters.pop();
 }
 return [[], full];
}
export const timeText = n => {n=Math.max(0,Math.floor(n||0));return `${Math.floor(n/60)}:${String(n%60).padStart(2,'0')}`;};

export function manualCompletion(previous, duration, done) {
  return {
    ...previous, position: 0, duration: previous?.duration || duration,
    completed: done, modified: previous?.modified ?? 0, hidden: previous?.hidden ?? true
  };
}

export function playbackProgress(previous, position, duration, modified) {
  const done = !!previous?.completed || completed(position, duration);
  return {
    ...previous, position: done ? 0 : position, duration, completed: done, modified,
    hidden: previous?.hidden ?? false
  };
}

export function recentEntries(progress) {
  return [...progress]
    .filter(([,record]) => !record.hidden)
    .sort((a,b) => b[1].modified - a[1].modified)
    .slice(0,500);
}

export function newCourses(series) {
 return series.filter(course => course.status === 'ongoing')
   .sort((a, b) => b.updatedAt - a.updatedAt)
   .slice(0, 10);
}
