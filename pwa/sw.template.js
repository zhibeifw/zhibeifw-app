// prepare.py 按界面文件内容生成版本，同一页面始终使用同一套资源。
const scope = self.registration.scope;
const appOrigin = new URL(scope).origin;
const prefix = 'zbfw-shell:' + scope + ':';
const shell = prefix + '{{revision}}';
const icons = 'zbfw-icons:' + scope;
const covers = 'zbfw-covers:' + scope;
const coverAvailability = new Map();
const files = {{files}};
const paths = new Set(files.map(file => new URL(file, scope).href));
const installIcons = new Set(['icon.png', 'icon-192.png', 'icon-512.png']
  .map(name => new URL('assets/' + name, scope).href));

self.addEventListener('install', event => {
  event.waitUntil(caches.open(shell).then(cache =>
    cache.addAll(files.map(file => new Request(new URL(file, scope), {cache: 'reload'})))
  ));
});

self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    for (const key of await caches.keys()) {
      if (key.startsWith(prefix) && key !== shell) await caches.delete(key);
    }
    // 早期预览的缓存由同源站点共用，只清理当前应用拥有的条目。
    if (await caches.has('zbfw-shell-v1')) {
      const old = await caches.open('zbfw-shell-v1');
      for (const request of await old.keys()) {
        if (paths.has(request.url) || installIcons.has(request.url) || request.url === scope) {
          await old.delete(request);
        }
      }
      if (!(await old.keys()).length) await caches.delete('zbfw-shell-v1');
    }
    await caches.delete(icons);
    await self.clients.claim();
  })());
});

self.addEventListener('message', event => {
  if (event.data === 'clear-cover-availability') coverAvailability.delete(event.source?.id);
});

self.addEventListener('fetch', event => {
  const request = event.request;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  url.hash = '';
  if (request.mode === 'navigate') url.search = '';
  const key = url.href === scope ? new URL('index.html', scope).href : url.href;
  if (paths.has(key)) {
    event.respondWith(caches.open(shell).then(async cache => await cache.match(key) || fetch(request)));
  } else if (installIcons.has(key)) {
    event.respondWith((async () => {
      const cache = await caches.open(icons);
      const hit = await cache.match(key);
      if (hit) return hit;
      const response = await fetch(request);
      if (response.ok) await cache.put(key, response.clone());
      return response;
    })());
  } else if (request.destination === 'image' && request.mode === 'cors' &&
             url.protocol === 'https:' && url.origin !== appOrigin && (!url.search || url.search === '?zbfw-cover')) {
    const original = url.search ? url.pathname.replace(/-(320|640)(\.[^./]+)$/, '$2') : url.pathname;
    url.search = '';
    event.respondWith(loadCover(event, url, original));
  }
});

async function loadCover(event, url, original) {
  let cache;
  try { cache = await caches.open(covers); } catch {}
  // 各条内容线路的相对路径指向同一份封面。
  const keyFor = path => new URL('cover-cache' + path, scope).href;
  const cached = path => cache?.match(keyFor(path)).catch(() => undefined);
  async function load(path) {
    const hit = await cached(path);
    if (hit) return hit;
    let response;
    try {
      const target = new URL(url);
      target.pathname = path;
      const request = target.href === event.request.url ? event.request : new Request(target, event.request);
      response = await fetch(request, cache ? {cache: 'reload'} : undefined);
    } catch {
      return Response.error();
    }
    if (cache && isCover(response)) event.waitUntil(cache.put(keyFor(path), response.clone()).catch(() => {}));
    return response;
  }
  if (url.pathname === original) return load(original);
  const tab = event.clientId;
  let available = coverAvailability.get(tab);
  if (!available) {
    available = {found: false, missing: new Set()};
    coverAvailability.set(tab, available);
    if (self.clients) event.waitUntil(self.clients.matchAll().then(clients => {
      const active = new Set(clients.map(client => client.id));
      for (const id of coverAvailability.keys()) if (id !== tab && !active.has(id)) coverAvailability.delete(id);
    }).catch(() => {}));
  }
  if (available.missing.has(original) || (!available.found && available.missing.size >= 3)) return load(original);
  const response = await load(url.pathname);
  if (isCover(response)) available.found = true;
  if (response.status === 404 || response.status === 403) {
    available.missing.add(original);
    return load(original);
  }
  return response.ok ? response : (await cached(original)) ?? response;
}

function isCover(response) {
  return response.ok && /^image\//i.test(response.headers.get('Content-Type') ?? '');
}
