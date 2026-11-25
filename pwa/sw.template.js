// prepare.py 按界面文件内容生成版本，同一页面始终使用同一套资源。
const scope = self.registration.scope;
const prefix = 'zbfw-shell:' + scope + ':';
const shell = prefix + '{{revision}}';
const icons = 'zbfw-icons:' + scope;
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
  }
});
