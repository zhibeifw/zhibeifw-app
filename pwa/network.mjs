import {validOrigin, parseCatalog, mediaURL} from './core.mjs';
import {read, write, cachedCatalog, cacheCatalog} from './storage.mjs';

const builtin = ['https://zbfw.org', 'https://zbfw.app'];
let origin, lastKnown, resolving, cached, restore, loading, routeRefresh, lastCheck = 0, stale = false;
export const currentOrigin = () => origin ?? lastKnown ?? cached?.origin;

export async function jsonResponse(url, limit, headers = {}, parent, timeoutMs = 15000) {
  const controller = new AbortController();
  const abort = () => controller.abort();
  let timer;
  function armTimeout() {
    clearTimeout(timer);
    timer = setTimeout(abort, timeoutMs);
  }
  if (parent?.aborted) abort();
  else parent?.addEventListener('abort', abort, {once:true});
  armTimeout();
  try {
    const response = await fetch(url, {
      headers, cache: 'no-cache', credentials: 'omit',
      signal: controller.signal
    });
    if (response.status === 304) return {notModified: true};
    if (response.status !== 200) throw Error('暂时无法连接');
    if (Number(response.headers.get('Content-Length')) > limit) throw Error('数据过大');
    const reader = response.body.getReader();
    const chunks = [];
    let size = 0;
    try {
      while (true) {
        const {value, done} = await reader.read();
        if (done) break;
        size += value.length;
        if (size > limit) throw Error('数据过大');
        chunks.push(value);
        if (!parent) armTimeout();
      }
    } finally {
      await reader.cancel();
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.length;
    }
    return {data: JSON.parse(new TextDecoder().decode(bytes)), etag: response.headers.get('ETag')};
  } finally {
    clearTimeout(timer);
    parent?.removeEventListener('abort', abort);
  }
}

async function resolveRoutes(current) {
  const stored = read('domains', []);
  const candidates = [read('origin', null), ...(Array.isArray(stored) ? stored.slice(0, 10) : []), ...builtin];
  const origins = [...new Set(candidates.filter(o => validOrigin(o) && o !== current))];
  const controller = new AbortController();
  let timer;
  async function probe(o) {
    const {data} = await jsonResponse(o + '/domains.json', 10240, {}, controller.signal, 5000);
    const domains = Array.isArray(data?.domains) ? data.domains.slice(0, 10).filter(validOrigin) : [];
    if (!domains.length) throw Error('线路无效');
    return {o, domains};
  }
  try {
    const checked = current ? await probe(current).catch(() => null) : null;
    const winner = checked ?? await new Promise((resolve, reject) => {
      let next = 0, pending = 0;
      function launch() {
        clearTimeout(timer);
        pending++;
        const index = next++;
        probe(origins[index]).then(resolve, () => {
          pending--;
          if (controller.signal.aborted) return;
          if (next < origins.length && next === index + 1) launch();
          else if (!pending) reject(Error('没有可用线路'));
        });
        if (next < origins.length) timer = setTimeout(launch, 1500);
      }
      if (origins.length) launch();
      else reject(Error('没有可用线路'));
    });
    origin = lastKnown = winner.o;
    write('origin', origin);
    write('domains', [...new Set(winner.domains)]);
    return origin;
  } catch {
    throw Error('暂时无法连接，请检查网络后重试');
  } finally {
    clearTimeout(timer);
    controller.abort();
  }
}

export function ensureOrigin() {
  return origin ?? (resolving ??= resolveRoutes().finally(() => { resolving = null; }));
}

export function restoreCatalog() {
  return restore ??= cachedCatalog().then(record => {
    if (!record || !validOrigin(record.origin)) return null;
    try {
      cached = {catalog: parseCatalog(record.raw), origin: record.origin, etag: record.etag};
      return cached.catalog;
    } catch {
      return null;
    }
  });
}

async function syncCatalog(reroute, onAttempt) {
  await restoreCatalog();
  let routeResult;
  if (reroute) {
    if (resolving) await resolving.catch(() => {});
    const before = origin ?? read('origin', null);
    const current = validOrigin(before) ? before : builtin[0];
    origin = undefined;
    try {
      resolving = resolveRoutes(current).finally(() => { resolving = null; });
      routeResult = await resolving === current ? '线路正常' : '已切换到备用线路，连接正常';
    } catch (error) {
      write('origin', null);
      return {catalog: cached?.catalog, stale, routeResult: '暂时无法连接'};
    }
  }
  const attempts = cached ? 1 : 3;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    if (!cached && !reroute) onAttempt?.(attempt);
    try {
      await fetchCatalog();
      stale = false;
      break;
    } catch (error) {
      if (attempt < attempts) {
        await new Promise(resolve => setTimeout(resolve, 2000 * attempt));
        continue;
      }
      if (!cached && !reroute) throw error;
      if (!reroute) stale = true;
    }
  }
  lastCheck = Date.now();
  return {catalog: cached?.catalog, stale, routeResult};
}

async function fetchCatalog() {
  await ensureOrigin();
  const etag = cached?.etag;
  const result = await jsonResponse(mediaURL(origin, 'index.json'), 10 * 1024 * 1024,
    etag ? {'If-None-Match': etag} : {});
  if (!result.notModified) {
    const catalog = parseCatalog(result.data);
    cached = {origin, etag: result.etag, catalog};
    await cacheCatalog({origin, etag: result.etag, raw: result.data});
  } else if (!etag) {
    throw Error('课程目录响应无效');
  }
}

export async function loadCatalog(force = false, reroute = false, onAttempt) {
  if (loading) {
    if (!reroute || routeRefresh) return loading;
    await loading.catch(() => {});
    return loadCatalog(true, true);
  }
  if (!force && cached && Date.now() - lastCheck < 60000) return {catalog: cached.catalog, stale};
  routeRefresh = reroute;
  loading = syncCatalog(reroute, onAttempt);
  try {
    return await loading;
  } finally {
    loading = null;
  }
}
