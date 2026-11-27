import {validPath,mediaURL,coverSourcePath,searchCourses,limitSearchText,normalizeQuery,newCourses,timeText,manualCompletion,playbackProgress,recentEntries,nativeCourseLink} from './core.mjs';
import {read,write,readRecords,writeRecord,recordCollection} from './storage.mjs';
import {loadAppNotice,loadCatalog,currentOrigin,ensureOrigin,restoreCatalog} from './network.mjs';
import {version} from './assets/version.mjs';
import {palette,icons} from './assets/design.mjs';
const $=s=>document.querySelector(s),main=$('#content'),audio=$('#audio');
const seekInput = $('#seek');
const playerDetails = seekInput.closest('.player-details');
const sleepButton = $('#sleep');
const speedInput = $('#speed');
let catalog=null,current=null,context='series',positionReady=false,pendingPosition=0,saveTime=0,waiting=false,reverse=false,stale=false;
let favorites=readRecords('favorites');
let progress=readRecords('progress');
let noticeTimer, lastSavedPosition;
let startedPlaying = false, revealOnPlay = true;
let stopAfterEpisode = false;
let checkingRoute = false, aboutRouteResult = '', initialRouteResult = '';
function notice(text){$('#notice').textContent=text;$('#notice').hidden=false;clearTimeout(noticeTimer);noticeTimer=setTimeout(()=>$('#notice').hidden=true,5000);}
function persist(id){if(!writeRecord('progress',id,progress.get(id)))notice('浏览器暂时无法保存收听记录');}
function el(tag,attrs={},...children){const node=document.createElement(tag);for(const [key,value] of Object.entries(attrs)){if(value==null)continue;if(key==='class')node.className=value;else if(key==='text')node.textContent=value;else if(key.startsWith('on'))node.addEventListener(key.slice(2),value);else node.setAttribute(key,String(value));}for(const c of children.flat())if(c!=null)node.append(c instanceof Node?c:document.createTextNode(String(c)));return node;}
function icon(name){const node=el('i',{'aria-hidden':'true'});node.style.setProperty('--icon',`url("./assets/${name}_24px.svg")`);return node;}
function setIcon(node,name){node.replaceChildren(icon(name));}
const appNoticeRegion=el('aside',{class:'app-notice','aria-label':'公告',hidden:''});
const dismissedAppNotices=new Set();
const appNoticePreference=key=>'appNotice.dismissed.'+key;
let appNoticeRequest, lastAppNoticeCheck=0;
function refreshAppNotice(force){
 if(appNoticeRequest || (!force && Date.now()-lastAppNoticeCheck<60000))return;
 lastAppNoticeCheck=Date.now();
 appNoticeRequest=loadAppNotice().then(value=>{
  if(!value || dismissedAppNotices.has(value.dismissalKey) || read(appNoticePreference(value.dismissalKey),false)){
   appNoticeRegion.hidden=true;
   appNoticeRegion.replaceChildren();
   return;
  }
  const link=value.link && el('a',{href:value.link.url,target:'_blank',rel:'noopener noreferrer'},value.link.label,icon('chevron_right'));
  const close=el('button',{type:'button','aria-label':'关闭公告',onclick:()=>{
   dismissedAppNotices.add(value.dismissalKey);
   write(appNoticePreference(value.dismissalKey),true);
   appNoticeRegion.hidden=true;
   appNoticeRegion.replaceChildren();
  }},icon('close'));
  appNoticeRegion.replaceChildren(el('div',{class:'app-notice-content'},el('p',{},value.message),link),close);
  appNoticeRegion.hidden=false;
 }).finally(()=>{appNoticeRequest=null;});
}
for(const i of document.querySelectorAll('[data-icon]'))i.style.setProperty('--icon',`url("./assets/${i.dataset.icon}_24px.svg")`);
const route=(type,id='')=>'#'+type+(id?'/'+encodeURIComponent(id):'');
function getRoute(){const [type='home',...parts]=location.hash.slice(1).split('/');try{return [type||'home',decodeURIComponent(parts.join('/'))];}catch{return ['home',''];}}
const findSeries=id=>catalog?.series.find(s=>s.id===id);
function findEpisode(id){for(const s of catalog?.series??[]){const e=s.episodes.find(e=>e.id===id);if(e)return {s,e};}return null;}
const coverObserver = new ResizeObserver(entries => {
 for (const {target, contentRect} of entries) updateCover(target, contentRect.width);
});
function watchCoverDensity() {
 matchMedia(`(resolution: ${window.devicePixelRatio}dppx)`).addEventListener('change', () => {
  for (const image of document.querySelectorAll('img[data-cover-path]')) {
   updateCover(image, image.getBoundingClientRect().width);
  }
  watchCoverDensity();
 }, {once:true});
}
watchCoverDensity();
function setCoverImage(image,path){
 const origin = currentOrigin();
 if (image.dataset.coverPath === path && image.dataset.coverOrigin === origin) return;
 image.dataset.coverPath = path;
 image.dataset.coverOrigin = origin;
 delete image.dataset.coverSrc;
 image.onerror = null;
 image.removeAttribute('src');
 coverObserver.observe(image);
 if (image.isConnected) updateCover(image, image.getBoundingClientRect().width);
}
function updateCover(image, width) {
 const {coverPath: path, coverOrigin: origin} = image.dataset;
 if (width <= 0 || !validPath(path)) return;
 const source = coverSourcePath(path, Math.floor(width * window.devicePixelRatio));
 const original = mediaURL(origin, path);
 const src = source === path ? original : mediaURL(origin, source) + '?zbfw-cover';
 if (image.dataset.coverSrc === src) return;
 image.dataset.coverSrc = src;
 image.style.visibility='';
 image.onerror=()=>{
  if (image.getAttribute('src') === src && src !== original) {
   image.src = original;
   return;
  }
  if(image.hasAttribute('crossorigin')){
   image.removeAttribute('crossorigin');
   image.src=original;
   return;
  }
  image.removeAttribute('src');
  image.style.visibility='hidden';
 };
 image.crossOrigin='anonymous';
 image.src=src;
}
function cover(s,loading='lazy'){
 if(!validPath(s.coverPath))return el('span',{class:'cover'});
 const image=el('img',{class:'cover',alt:'',loading,decoding:'async'});
 setCoverImage(image,s.coverPath);
 return image;
}
const courseStatus=s=>s.status==='completed'?'已完结':'更新中';
function card(s, detail, title=s.title){
 return el('a',{class:'card',href:route('series',s.id)},cover(s),el('strong',{},title),detail?el('small',{},detail):null);
}
function section(name,items,layout='',href){
 if(!items.length)return null;
 const shelf=el('div',{class:'shelf '+layout},items);
 const heading=href?el('a',{class:'section-link',href},name,icon('chevron_right')):name;
 const controls=el('div',{class:'shelf-controls',hidden:true});
 for(const [direction,label] of [[-1,'上一组'],[1,'下一组']]){
  controls.append(el('button',{'aria-label':name+'，'+label,onclick:()=>{
   shelf.scrollBy({left:direction*(shelf.clientWidth+parseFloat(getComputedStyle(shelf).columnGap)),
    behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'instant':'smooth'});
  }},icon('chevron_right')));
 }
 const update=()=>{
  controls.hidden=shelf.scrollWidth<=shelf.clientWidth+1;
  controls.firstChild.disabled=shelf.scrollLeft<1;
  controls.lastChild.disabled=shelf.scrollLeft+shelf.clientWidth>=shelf.scrollWidth-1;
 };
 shelf.addEventListener('scroll',update,{passive:true});
 shelfObserver.observe(shelf);
 shelf.updatesControls=update;
 return el('section',{class:'section'},el('div',{class:'section-head'},el('h2',{},heading),controls),shelf);
}
const shelfObserver=new ResizeObserver(entries=>{
 for(const {target} of entries)target.updatesControls();
});

function empty(title,detail='',symbol='library_books'){return el('div',{class:'empty'},icon(symbol),el('h2',{},title),el('p',{},detail));}
function pageTitle(title,action){main.append(el('div',{class:'page-head'},el('h1',{},title),action));document.title=title+' · 智悲佛网';}
function playbackLabel(e) {
 const saved = progress.get(e.id);
 const duration = (current?.e.id === e.id && Number.isFinite(audio.duration) ? audio.duration : 0) || saved?.duration || e.duration;
 if (saved?.completed) return !duration ? '已听完' : Math.max(1, Math.round(duration / 60)) + ' 分钟';
 if (!duration) return '播放';
 const position = current?.e.id===e.id && positionReady ? audio.currentTime : saved?.position;
 return position > 0 ? '剩 ' + timeText(Math.max(0, duration-position)) : Math.max(1, Math.round(duration/60))+' 分钟';
}
function updateCurrentEpisodeTime() {
 if (!current) return;
 const {e} = current;
 const row = main.querySelector(`[data-row="${e.id}"]`);
 const label = row?.querySelector('small span');
 if (!label) return;
 const text = (row.classList.contains('recent-row') ? e.title + ' · ' : '') + playbackLabel(e);
 if (label.textContent !== text) label.textContent = text;
}
const completionIcon = done => done ? 'lesson-unmark' : 'lesson-mark';
function episodeRow(s,e,recent=false,unavailable=false){
 const time=el('small',{},recent?null:icon('refresh'),el('span',{},(recent?e.title+' · ':'')+playbackLabel(e)));
 const mainButton=el('button',{class:'episode-main','data-episode':e.id,onclick:()=>unavailable?notice(findSeries(s.id)?'这一集已下架':'这门课已下架'):play(s,e,recent?'single':'series')},icon('play_arrow_fill1'),recent?cover(s):null,el('span',{class:'episode-title'},el('strong',{},recent?s.title:e.title),time));
 let action;
 if(recent && !findSeries(s.id))action=null;
 else if(recent)action=el('a',{class:'row-action',href:route('series',s.id),'aria-label':'前往课程 '+s.title,title:'前往课程'},icon('arrow_circle_right'));
 else{const done=!!progress.get(e.id)?.completed;action=el('button',{class:'row-action','aria-label':done?'标记为未听完':'标记为已听完','aria-pressed':done,title:done?'标记为未听完':'标记为已听完',onclick:()=>markCompleted(s,e,!progress.get(e.id)?.completed)},icon(completionIcon(done)));}
 return el('li',{class:recent?'episode recent-row':'episode track','data-row':e.id},mainButton,action);
}
function savedCourseTitle(id){
 const favoriteTitle=favorites.get(id)?.title?.trim();
 if(favoriteTitle)return favoriteTitle;
 let latest;
 for(const entry of progress.values()){
  if(entry.seriesId===id && entry.seriesTitle?.trim() && (!latest || (entry.modified??0)>(latest.modified??0)))latest=entry;
 }
 return latest?.seriesTitle?.trim();
}
function toggleFavorite(id){
 const series=findSeries(id) ?? current?.s;
 const value = !favorites.has(id) && {title:series.title,coverPath:series.coverPath,addedAt:Date.now()};
 if(value) favorites.set(id,value);
 else favorites.delete(id);
 if(!writeRecord('favorites',id,value)) notice('浏览器暂时无法保存收藏');
 navigator.storage?.persist?.().catch(()=>{});
 render();
}
function markCompleted(s,e,done){
 if (current?.e.id === e.id) {
  if (done) {
   audio.pause();
   pendingPosition = 0;
   audio.currentTime = 0;
  }
  lastSavedPosition = audio.currentTime;
 }
 progress.set(e.id,manualCompletion(progress.get(e.id),e.duration,done));
 persist(e.id);
 render();
}
function render(){
 if(!catalog)return;
 const [type,id]=getRoute();
 shelfObserver.disconnect();
 for (const image of main.querySelectorAll('img[data-cover-path]')) coverObserver.unobserve(image);
 main.replaceChildren();
 document.body.dataset.page=type;
 for(const a of document.querySelectorAll('[data-nav]')){if(a.dataset.nav===(type==='category'||type==='series'?'categories':type))a.setAttribute('aria-current','page');else a.removeAttribute('aria-current');}
 if(type==='home'){
  pageTitle('主页');
  if(stale && navigator.onLine)main.append(el('p',{class:'muted'},'无法更新，显示的是上一次更新的内容',el('button',{onclick:()=>refresh(true)},'重试')));
  main.append(appNoticeRegion);
  const ongoing=newCourses(catalog.series).map(course=>{
   const last=course.episodes.at(-1);
   return card(course,last?'更新至 '+last.title:'');
  });
  const featured=new Map();
  for(const item of catalog.featured){
   const course=findSeries(item.seriesId);
   if(!course||featured.has(course.id))continue;
   featured.set(course.id,card(course,'',item.title || course.title));
  }
  main.append(...[section('新课程',ongoing,'featured'),section('编辑精选',[...featured.values()])].filter(Boolean));
  for(const c of catalog.categories){
   const list=catalog.series.filter(s=>s.categoryId===c.id).slice(0,10);
   if(list.length)main.append(section(c.name,list.map(s=>card(s,'')),'',route('category',c.id)));
  }
 }else if(type==='categories'){
  pageTitle('分类');const order=catalog.categoryOrder;const cats=[...catalog.categories].sort((a,b)=>(order.includes(a.id)?order.indexOf(a.id):999)-(order.includes(b.id)?order.indexOf(b.id):999));
  main.append(el('div',{class:'categories'},cats.map(c=>{const a=el('a',{class:'category',href:route('category',c.id)},icon(icons[categoryIcon(c)]?.material||'menu_book'),el('span',{},c.name));a.style.backgroundColor=categoryColor(c);return a;})));
 }else if(type==='category'){
  const c=catalog.categories.find(c=>c.id===id);main.append(el('a',{class:'crumb',href:'#categories'},icon('arrow_back'),'分类'));pageTitle(c?.name??'分类');const list=catalog.series.filter(s=>s.categoryId===id);main.append(list.length?el('div',{class:'grid'},list.map(s=>card(s,courseStatus(s)))):empty('暂无课程'));
 }else if(type==='series'){
  const s=findSeries(id);
  if(!s){
   const title=savedCourseTitle(id);
   const state=empty(title || '这门课已下架',title?'已下架':'','menu_book');
   if(favorites.has(id))state.append(el('button',{onclick:()=>toggleFavorite(id)},'取消收藏'));
   main.append(state);document.title=(title || '这门课已下架')+' · 智悲佛网';return;
  }
  const c=catalog.categories.find(c=>c.id===s.categoryId);
  const isFavorite=favorites.has(id);
  const info=el('div',{class:'series-info'},el('h1',{},s.title),
   el('p',{class:'album-meta'},el('a',{href:route('category',s.categoryId)},c?.name),
    (s.episodes.length?' · 共 '+s.episodes.length+' 节课':'')+' · '+courseStatus(s)));
  if(s.description)info.append(el('details',{class:'introduction'},el('summary',{},'课程简介'),el('p',{class:'description'},s.description)));
  const appLink=nativeCourseLink(id,location.href,navigator.userAgent);
  info.append(el('div',{class:'actions'},
   el('button',{'aria-pressed':isFavorite,onclick:()=>toggleFavorite(id)},icon(isFavorite?'bookmark_fill1':'bookmark'),isFavorite?'已收藏':'收藏'),
   appLink && el('a',{href:appLink},'在 App 中打开')));
  main.append(el('section',{class:'series-heading'},cover(s,'eager'),info),el('div',{class:'section-head track-head'},el('h2',{},'全部课程'),el('button',{onclick:()=>{reverse=!reverse;render();}},icon('swap_vert'),reverse?' 从新到旧':' 从旧到新')),el('ul',{class:'episode-list'},(reverse?[...s.episodes].reverse():s.episodes).map(e=>episodeRow(s,e))));document.title=s.title+' · 智悲佛网';
 }else if(type==='recent'){
  const entries=recentEntries(progress);
  pageTitle('最近播放',entries.length?el('button',{class:'danger',onclick:clearRecent},icon('delete'),' 清空'):null);
  main.append(entries.length?el('p',{class:'muted'},`${entries.length} 条记录`):empty('暂无收听记录','','history'));
  main.append(el('ul',{class:'episode-list'},entries.map(([id,p])=>{
   const episode=findEpisode(id);
   if(episode)return episodeRow(episode.s,episode.e,true);
   const series=findSeries(p.seriesId) ?? {id:p.seriesId,title:p.seriesTitle || id,coverPath:p.coverPath};
   return episodeRow(series,{id,title:p.episodeTitle || id,duration:p.duration},true,true);
  } )));
 }else if(type==='favorites'){
  pageTitle('收藏');
  const cards=[...favorites].sort((a,b)=>(b[1].addedAt??0)-(a[1].addedAt??0)).map(([id,record])=>{
   const series=findSeries(id);
   if(series)return card(series,courseStatus(series));
   const title=savedCourseTitle(id) || '已下架的课程';
   return el('div',{class:'unavailable'},card({id,title,coverPath:record.coverPath},'已下架'),
    el('button',{onclick:()=>toggleFavorite(id),'aria-label':'取消收藏 '+title},'取消收藏'));
  });
  if(cards.length)main.append(el('p',{class:'muted'},cards.length+' 门课'));
  main.append(cards.length?el('div',{class:'grid'},cards):empty('暂无收藏','','bookmark'));
 }else if(type==='search'){
  pageTitle('搜索');
  const query=limitSearchText(id);
  const input=el('input',{type:'search',placeholder:'课程名','aria-label':'课程名',value:query});
  input.addEventListener('input',event=>{
   if(event.isComposing)return;
   const limited=limitSearchText(input.value);
   if(input.value!==limited)input.value=limited;
   if(query && !input.value){
    history.replaceState(null,'',route('search'));
    render();
    main.querySelector('input[type="search"]').focus();
   }
  });
  main.append(el('form',{class:'search-form',role:'search',onsubmit:event=>{
   event.preventDefault();location.hash=route('search',limitSearchText(input.value).trim());
  }},input,el('button',{class:'filled',type:'submit'},'搜索')));
  if(query){const [results,matched]=searchCourses(catalog.series,query);if(results.length && matched!==normalizeQuery(query))main.append(el('p',{class:'muted'},`已显示“${matched}”的结果`));main.append(results.length?el('div',{class:'grid'},results.map(s=>card(s,courseStatus(s)))):empty('未找到相关内容','','search'));}
  else main.append(empty('输入课程名搜索','','search'));
 }else if(type==='about')renderAbout();
 else{location.hash='#home';return;}
 syncPlaybackUI();
}
function categoryHash(id, salt=0){
 let value=0x811c9dc5 ^ salt;
 for(let i=0;i<id.length;i++)value=Math.imul(value^id.charCodeAt(i),0x01000193);
 return value>>>0;
}
const randomCategoryIcons=['school-outline','shield-checkmark-outline','planet-outline','infinite-outline','bulb-outline','flower-outline','book-outline','leaf-outline','accessibility-outline','flame-outline','library-outline','chatbubble-ellipses-outline','sunny-outline','moon-outline','star-outline','heart-outline','cloudy-outline','water-outline'];
function categoryIcon(c){return c.icon==='random'?randomCategoryIcons[categoryHash(c.id,0x5a)%randomCategoryIcons.length]:c.icon;}
function categoryColor(c){const names=['orange','blue','purple','pink','teal','olive','green','brown','red','amber','magenta','indigo','slate','forest','cocoa','cyan','wine','charcoal'];const values=[...palette.colors,...palette.categoryExtraColors];return values[names.indexOf(c.color)]??palette.colors[categoryHash(c.id)%palette.colors.length];}
let clearingCache=false, cacheResult='';
async function clearCache(){
 if(clearingCache)return;
 clearingCache=true;
 updateSettingsFeedback();
 try{
  if(window.caches){
   const scope=new URL('./',location.href).href;
   await Promise.all(['zbfw-icons:', 'zbfw-covers:'].map(prefix=>caches.delete(prefix + scope)));
   navigator.serviceWorker?.controller?.postMessage('clear-cover-availability');
  }
  cacheResult='已清除';
 }catch{cacheResult='清除失败';}
 finally{clearingCache=false;updateSettingsFeedback();}
}
function renderAbout(){
 pageTitle('关于');const settings=el('div',{class:'settings'});
 const group=(name,rows)=>el('section',{class:'setting-group'},el('h2',{},name),rows);
 settings.append(group('设置',[
  el('button',{id:'clear-cache',class:'setting-row',onclick:clearCache},icon('delete'),'清除缓存',
    el('span',{class:'muted','aria-live':'polite'},clearingCache?'正在清除…':cacheResult)),
  el('button',{id:'check-route',class:'setting-row',onclick:checkRoute},icon('refresh'),'刷新网络线路',
    el('span',{class:'muted','aria-live':'polite'},checkingRoute?'正在检测…':aboutRouteResult)),
 ]),group('关于',[
  el('a',{class:'setting-row',href:'mailto:hello@zhibeifw.com'},icon('chat'),'联系',el('span',{class:'muted'},'hello@zhibeifw.com')),
  el('a',{class:'setting-row',href:'https://zhibeifw.com/privacy',target:'_blank',rel:'noopener'},icon('verified_user'),'隐私政策'),
  el('a',{class:'setting-row',href:'https://github.com/zhibeifw/zhibeifw-app',target:'_blank',rel:'noopener'},icon('public'),'源代码'),
 ]),el('div',{class:'signature'},'智悲佛网',el('br'),'网页版 '+version));
 main.append(settings);
 updateSettingsFeedback();
}
function clearRecent(){const d=$('#confirm');$('#confirm-title').textContent='清空最近列表？';$('#confirm-text').textContent='列表中的记录会被移除。各课程的收听进度、已听完标记不受影响。';d.returnValue='cancel';d.showModal();d.addEventListener('close',()=>{if(d.returnValue!=='ok')return;for(const [id,p] of progress){if(!p.hidden){p.hidden=true;persist(id);}}render();},{once:true});}
function updateSettingsFeedback(){
 const routeButton=$('#check-route'),cacheButton=$('#clear-cache');
 if(routeButton){
  routeButton.setAttribute('aria-disabled',String(checkingRoute));
  routeButton.querySelector('span').textContent=checkingRoute?'正在检测…':catalog?aboutRouteResult:initialRouteResult;
 }
 if(cacheButton){
  cacheButton.setAttribute('aria-disabled',String(clearingCache));
  cacheButton.querySelector('span').textContent=clearingCache?'正在清除…':cacheResult;
 }
 const retry=$('#initial-retry');
 if(retry)retry.disabled=checkingRoute;
}
async function checkRoute(){
 if(checkingRoute)return;
 const initial=!catalog;
 checkingRoute=true;
 updateSettingsFeedback();
 try{
  const result=await refresh(true,true);
  if(initial)initialRouteResult=result;else aboutRouteResult=result;
 }finally{
  checkingRoute=false;
  updateSettingsFeedback();
 }
}
function renderInitialFailure(){
 main.replaceChildren(empty('暂时无法连接'),el('button',{id:'initial-retry',class:'filled',onclick:()=>refresh(true)},'重试'),
  el('button',{id:'check-route',onclick:checkRoute},'刷新网络线路 ',el('span',{'aria-live':'polite'})));
 updateSettingsFeedback();
}
async function refresh(force=false,reroute=false){
 try{
  if(!reroute)refreshAppNotice(force);
  const result=await loadCatalog(force,reroute,attempt=>{
   main.replaceChildren(el('div',{class:'empty','aria-live':'polite'},
    el('progress',{'aria-label':'加载中…'}),el('h2',{},'正在准备内容…'),el('p',{},'第一次使用需要联网，请稍候'),
    attempt>1?el('p',{},'正在重新连接（第 '+attempt+' 次）'):null));
  });
  if(reroute && result.routeResult!=='暂时无法连接')refreshAppNotice(true);
  if(catalog!==result.catalog||stale!==result.stale){
   const enteringApp=!catalog && result.catalog;
   catalog=result.catalog;stale=result.stale;
   if(enteringApp || getRoute()[0]!=='about')render();
  }
  return result.routeResult;
 }catch(error){
  if(!catalog)renderInitialFailure();
  return '暂时无法连接';
 }
}
function save(){
 if(!current || !startedPlaying || !positionReady || audio.error || !Number.isFinite(audio.currentTime)) return;
 if(lastSavedPosition===audio.currentTime) return;
 lastSavedPosition=audio.currentTime;
 const {e} = current;
 const old = progress.get(e.id);
 const duration = Number.isFinite(audio.duration) ? audio.duration : old?.duration || e.duration;
 const record = playbackProgress(old, audio.currentTime, duration, Date.now());
 progress.set(e.id,record);
 persist(e.id);
 saveTime=record.modified;
 if(!!old?.completed!==record.completed) syncPlaybackUI();
}
function play(s,e,ctx='series'){
 if(!e)return;
 if(current?.e.id===e.id){context=ctx;toggle();return;}
 startEpisode(s,e,ctx);
}
let playbackRequest=0;
async function startEpisode(s,e,ctx){
 const request=++playbackRequest;
 let origin;
 try{
  const route=ensureOrigin();
  origin=typeof route==='string'?route:await route;
 }catch{
  if(request===playbackRequest)notice('暂时无法连接');
  return;
 }
 if(request!==playbackRequest)return;
 stopStallWatch();
 if(playbackDialog.open)playbackDialog.close();
 failedSource=false;
 save();audio.pause();current={s,e};context=ctx;positionReady=false;waiting=true;lastSavedPosition=undefined;
 const saved=progress.get(e.id);pendingPosition=saved?.completed?0:saved?.position||0;
 startedPlaying=false;
 revealOnPlay=true;
 audio.defaultPlaybackRate=Number(speedInput.value);
 audio.src=mediaURL(origin,e.audioPath);
 $('#player').hidden=false;$('#toggle').disabled=false;$('#now-title').textContent=s.title;$('#now-episode').textContent=e.title;setCoverImage($('#now-cover'),s.coverPath);$('#now-link').href=route('series',s.id);
 updateMediaSession();startAudio();syncPlaybackUI();navigator.storage?.persist?.().catch(()=>{});
}
let stallWatch, failedSource=false;
const playbackDialog = $('#playback-error');
function stopStallWatch(){
 if(!stallWatch)return;
 clearTimeout(stallWatch.probe);
 clearTimeout(stallWatch.deadline);
 stallWatch.controller.abort();
 stallWatch=null;
}
async function audioRemoved(url,signal){
 try{
  const response=await fetch(url,{method:'HEAD',credentials:'omit',cache:'no-store',
   signal:AbortSignal.any([signal,AbortSignal.timeout(5000)])});
  return response.status===404 || response.status===410;
 }catch{return false;}
}
function showPlaybackFailure(removed){
 if(failedSource || !current)return;
 failedSource=true;
 stopStallWatch();
 audio.pause();
 waiting=false;
 syncPlaybackUI();
 $('#playback-message').textContent=removed?'这一集已下架':'网络异常，请检查网络后重试';
 $('#playback-retry').hidden=removed;
 $('#playback-close').textContent=removed?'好':'关闭';
 if(!playbackDialog.open)playbackDialog.showModal();
}
function watchStall(){
 if(stallWatch || failedSource || !current || audio.paused)return;
 const watch={controller:new AbortController()};
 const url=audio.currentSrc || audio.src;
 stallWatch=watch;
 watch.probe=setTimeout(async()=>{
  if(await audioRemoved(url,watch.controller.signal) && stallWatch===watch)showPlaybackFailure(true);
 },5000);
 watch.deadline=setTimeout(()=>{if(stallWatch===watch)showPlaybackFailure(false);},30000);
}
async function mediaError(){
 if(!current || !audio.error || failedSource)return;
 const request=playbackRequest;
 const removed=await audioRemoved(audio.currentSrc || audio.src,AbortSignal.timeout(5000));
 if(request===playbackRequest && audio.error)showPlaybackFailure(removed);
}
$('#playback-retry').onclick=()=>{
 playbackDialog.close();
 if(current)startEpisode(current.s,current.e,context);
};
function startAudio(){
 const request=playbackRequest;
 audio.play().catch(error=>{
  if(request!==playbackRequest || error.name==='AbortError' || audio.error)return;
  if(error.name==='NotAllowedError'){
   waiting=false;
   notice('请点播放按钮开始收听');
   syncPlaybackUI();
  }else showPlaybackFailure(false);
 });
}
function toggle(){
 playbackRequest++;
 if(!current)return;
 const record=progress.get(current.e.id);
 if(failedSource || audio.error || audio.ended || (audio.paused && record?.completed)){
  startEpisode(current.s,current.e,context);
 }else if(!audio.paused){
  audio.pause();
 }else{
  revealOnPlay=true;
  waiting=audio.readyState<3;
  startAudio();
 }
 syncPlaybackUI();
}
function syncPlaybackUI(){const on=!!current&&!audio.paused&&!audio.ended&&!audio.error;
 updateCurrentEpisodeTime();
 for (const btn of document.querySelectorAll('[data-episode]')) {
  const id = btn.dataset.episode, row = btn.closest('.episode');
  const recent = row.classList.contains('recent-row');
  const playing = id === current?.e.id && on;
  const replay = !!progress.get(id)?.completed;
  row.classList.toggle('completed', replay);
  row.classList.toggle('active', id === current?.e.id);
  btn.firstChild.replaceWith(playing && waiting ? el('span',{class:'loading','aria-label':'加载中'}) : icon(playing ? 'pause_fill1' : recent && replay ? 'refresh' : 'play_arrow_fill1'));
  btn.setAttribute('aria-label', (playing ? '暂停 ' : replay ? '重新播放 ' : '播放 ') + btn.textContent);
 }
 if(current){
  const done=!!progress.get(current.e.id)?.completed;
  const label=done?'标记为未听完':'标记为已听完';
  const action=main.querySelector(`[data-row="${current.e.id}"] button.row-action`);
  if(action){
   action.setAttribute('aria-pressed',String(done));
   action.setAttribute('aria-label',label);
   action.title=label;
   setIcon(action,completionIcon(done));
  }
  $('#player-mark').textContent=label;
  $('#player-favorite').textContent=favorites.has(current.s.id)?'取消收藏':'收藏这门课';
  $('#player-series').href=route('series',current.s.id);
 }
 $('#toggle').setAttribute('aria-label',on?'暂停':'播放');if(on&&waiting)$('#toggle').replaceChildren(el('span',{class:'loading','aria-label':'加载中'}));else setIcon($('#toggle'),on?'pause_fill1':'play_arrow_fill1');
 if('mediaSession'in navigator)navigator.mediaSession.playbackState=on?'playing':'paused';updateSeek();
}
function canSeek(){
 return positionReady && audio.readyState>=HTMLMediaElement.HAVE_CURRENT_DATA && !audio.seeking &&
  Number.isFinite(audio.currentTime) && Number.isFinite(audio.duration) && audio.duration>0;
}
function showSeekPosition(position, duration) {
 const elapsed = timeText(position);
 $('#elapsed').textContent = elapsed;
 $('#remaining').textContent = '−' + timeText(Math.max(0, duration - position));
 const percent = duration > 0 ? Math.min(100, Math.max(0, position / duration * 100)) : 0;
 seekInput.style.setProperty('--seek-progress', percent + '%');
 seekInput.setAttribute('aria-valuetext', elapsed + ' / ' + timeText(duration));
}
function updateSeek(){
 if(!current)return;
 const duration=Number.isFinite(audio.duration)?audio.duration:progress.get(current.e.id)?.duration||0;
 const position=positionReady && Number.isFinite(audio.currentTime)?audio.currentTime:pendingPosition;
 seekInput.max=String(duration||1);
 if(!scrubbing)seekInput.value=String(position);
 showSeekPosition(scrubbing?seekInput.valueAsNumber:position,duration);
 const disabled=!canSeek();
 seekInput.disabled=disabled;$('#forward').disabled=disabled;$('#backward').disabled=disabled;
 updateSeekHighlight();
 if('mediaSession'in navigator&&navigator.mediaSession.setPositionState&&Number.isFinite(audio.duration)&&audio.duration>0){try{navigator.mediaSession.setPositionState({duration:audio.duration,position:Math.min(audio.currentTime,audio.duration),playbackRate:audio.playbackRate});}catch{}}
}
function seek(position){if(!canSeek()||!Number.isFinite(position))return;audio.currentTime=Math.max(0,Math.min(position,audio.duration));save();updateSeek();}
function updateMediaSession(){if(!('mediaSession'in navigator)||!current)return;const {s,e}=current;if('MediaMetadata'in window)navigator.mediaSession.metadata=new MediaMetadata({title:e.title,artist:'索达吉堪布',album:s.title,artwork:[{src:mediaURL(currentOrigin(),s.coverPath)}]});const handlers={play:()=>{if(audio.paused||audio.error)toggle();},pause:()=>audio.pause(),seekbackward:()=>seek(audio.currentTime-15),seekforward:()=>seek(audio.currentTime+30),seekto:d=>seek(d.seekTime),previoustrack:null,nexttrack:null};for(const [name,handler]of Object.entries(handlers))try{navigator.mediaSession.setActionHandler(name,handler);}catch{}}
audio.addEventListener('loadedmetadata',()=>{
 if(!current || audio.readyState<1)return;
 if(audio.playbackRate!==audio.defaultPlaybackRate)audio.playbackRate=audio.defaultPlaybackRate;
 if(pendingPosition>0 || !Number.isFinite(audio.currentTime)){
  audio.currentTime=Number.isFinite(audio.duration)?Math.min(pendingPosition,Math.max(0,audio.duration-1)):pendingPosition;
 }
 positionReady=true;
 updateSeek();
});
for(const event of ['loadeddata','seeking','seeked'])audio.addEventListener(event,updateSeek);
audio.addEventListener('playing',()=>{
 if(!current || audio.paused || failedSource)return;
 stopStallWatch();
 waiting=false;
 if(revealOnPlay){
  const {s,e}=current;
  const old=progress.get(e.id);
  progress.set(e.id,{...old,position:startedPlaying?audio.currentTime:pendingPosition,duration:old?.duration||e.duration,
   completed:false,modified:Date.now(),hidden:false,seriesId:s.id,seriesTitle:s.title,episodeTitle:e.title,coverPath:s.coverPath});
  persist(e.id);
  revealOnPlay=false;
  startedPlaying=true;
  if(['series','recent'].includes(getRoute()[0]))render();
 }
 syncPlaybackUI();
});
audio.addEventListener('waiting',()=>{watchStall();waiting=true;syncPlaybackUI();});
audio.addEventListener('pause',()=>{if(!audio.paused)return;stopStallWatch();save();waiting=false;syncPlaybackUI();});
audio.addEventListener('play',()=>{if(audio.readyState<3)watchStall();syncPlaybackUI();});
audio.addEventListener('timeupdate',()=>{
 updateSeek();
 updateCurrentEpisodeTime();
 if(Date.now()-saveTime>=5000)save();
});
audio.addEventListener('error',mediaError);
audio.addEventListener('ended',()=>{
 if(!audio.ended || failedSource)return;
 stopStallWatch();
 save();
 if(stopAfterEpisode){
  setStopAfterEpisode(false);
 }else if(context==='series' && current){
  const {s,e}=current;
  const next=s.episodes[s.episodes.findIndex(episode=>episode.id===e.id)+1];
  if(next){play(s,next);return;}
 }
 syncPlaybackUI();
 render();
});
const more=$('#player-more');
$('#player-mark').onclick=()=>{more.open=false;markCompleted(current.s,current.e,!progress.get(current.e.id)?.completed);};
$('#player-favorite').onclick=()=>{more.open=false;toggleFavorite(current.s.id);};
$('#player-series').onclick=()=>{more.open=false;};
document.addEventListener('click',event=>{if(more.open && !more.contains(event.target))more.open=false;});
document.addEventListener('keydown',event=>{
 if(event.key==='Escape' && more.open){more.open=false;more.querySelector('summary').focus();}
});
let scrubbing=false;
function updateSeekHighlight() {
 playerDetails.classList.toggle('seek-active', !seekInput.disabled &&
  (scrubbing || seekInput.matches(':hover, :focus-visible')));
}
for (const event of ['pointerenter','pointerleave','focus','blur'])
 seekInput.addEventListener(event, updateSeekHighlight);
seekInput.addEventListener('pointerdown',()=>{scrubbing=true;updateSeekHighlight();});
window.addEventListener('pointerup',()=>{scrubbing=false;updateSeekHighlight();});
window.addEventListener('pointercancel',()=>{scrubbing=false;updateSeek();});
$('#toggle').onclick=toggle;
$('#backward').onclick=()=>seek(audio.currentTime-15);
$('#forward').onclick=()=>seek(audio.currentTime+30);
function setStopAfterEpisode(enabled){
 stopAfterEpisode=enabled;
 sleepButton.setAttribute('aria-pressed',String(enabled));
 sleepButton.title=enabled?'取消本集播完后停止':'本集播完后停止';
 setIcon(sleepButton,enabled?'bedtime_fill1':'bedtime');
}
sleepButton.onclick=()=>setStopAfterEpisode(!stopAfterEpisode);
seekInput.oninput=()=>showSeekPosition(seekInput.valueAsNumber, Number(seekInput.max));
seekInput.onchange=()=>seek(seekInput.valueAsNumber);
speedInput.addEventListener('pointerdown',()=>{speedInput.dataset.pointerFocus='';});
for (const event of ['keydown','blur'])
 speedInput.addEventListener(event,()=>{delete speedInput.dataset.pointerFocus;});
speedInput.onchange=()=>{
 audio.defaultPlaybackRate=audio.playbackRate=Number(speedInput.value);
 $('#speed-label').textContent=speedInput.value+'×';
 updateSeek();
};
$('.skip').onclick=e=>{e.preventDefault();main.focus();};
function setNavigation(open){
 document.body.classList.toggle('nav-open',open);
 const button=$('#nav-toggle');
 button.setAttribute('aria-expanded',String(open));
 button.setAttribute('aria-label',open?'关闭导航':'打开导航');
}
$('#nav-toggle').onclick=()=>setNavigation(!document.body.classList.contains('nav-open'));
for (const area of document.querySelectorAll('#sidebar, .site-header'))
 area.addEventListener('click',event=>{if(event.target.closest('a')) setNavigation(false);});
document.addEventListener('keydown',event=>{
 if(event.key==='Escape' && document.body.classList.contains('nav-open')){
  setNavigation(false);
  $('#nav-toggle').focus();
 }
});
window.addEventListener('hashchange',()=>{setNavigation(false);reverse=false;render();window.scrollTo(0,0);main.focus({preventScroll:true});});
window.addEventListener('storage',event=>{
 const name=recordCollection(event.key);
 if(name==='favorites')favorites=readRecords(name);
 else if(name==='progress')progress=readRecords(name);
 else return;
 if(['favorites','recent','series'].includes(getRoute()[0]))render();
 else syncPlaybackUI();
});
window.addEventListener('pagehide',save);document.addEventListener('visibilitychange',()=>{if(document.hidden)save();else refresh();});
window.addEventListener('offline',()=>{if(stale && getRoute()[0]==='home')render();notice('网络已断开，播放需要联网');});window.addEventListener('online',async()=>{
 await refresh(true);
 if(catalog && stale && getRoute()[0]==='home')render();
});
document.addEventListener('keydown',e=>{if(e.code==='Space'&&e.target===document.body&&current){e.preventDefault();toggle();}});
if('serviceWorker' in navigator) navigator.serviceWorker.register('./sw.js', {updateViaCache:'none'}).catch(()=>{});
catalog=await restoreCatalog();
if(catalog) render();
await refresh();
