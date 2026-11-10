// One keyed bundle for Filip's other projects: the whole fleet file (wraps included), both
// live feeds and routes metadata in one call. The routes body stays at /v1/routes: decompressing
// and embedding several MB here would blow the free plan's 10 ms CPU budget.
//
// czynaczas.pl's remarks are deliberately not here. His terms forbid any bulk endpoint for his
// data, even a private one; /v1/remarks/<kind>/<number> stays one vehicle at a time.
//
//   GET /v1/master   Authorization: Bearer <ROUTES_UPLOAD_TOKEN>

import { fetchFeed } from './city.js';
import { loadFleet } from './lookup.js';

export async function getMaster(request, env) {
  if (request.method !== 'GET') return json({ result: 'GET only' }, 405);
  if (!(await authorized(request, env))) return json({ result: 'Unauthorized' }, 401);

  const [fleet, routes, bus, tram] = await Promise.all([
    loadFleet(),
    env.ROUTES.get('routes:meta', { type: 'json', cacheTtl: 300 }),
    live('1', env),
    live('2', env),
  ]);
  if (!fleet) return json({ result: "The fleet data isn't available right now; try again in a few minutes" }, 503);

  return new Response(JSON.stringify({
    generated: new Date().toISOString(),
    fleet,
    vehicles: { bus, tram },
    routes: routes ? { ...routes, url: '/v1/routes' } : null,
    remarks: { url: '/v1/remarks/{bus|tram}/{number}', bulk: false },
  }), {
    headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' },
  });
}

async function live(type, env) {
  const feed = await fetchFeed(type, env);
  if (!feed) return { source: null, result: null };
  try {
    return { source: feed.source, ...JSON.parse(feed.body) };
  } catch {
    return { source: feed.source, result: null };
  }
}

async function authorized(request, env) {
  return !!env.ROUTES_UPLOAD_TOKEN
    && sameText(request.headers.get('Authorization') ?? '', `Bearer ${env.ROUTES_UPLOAD_TOKEN}`);
}

// Compares hashes, so how long it takes doesn't give away how much of a guess was right.
async function sameText(a, b) {
  const enc = new TextEncoder();
  const [x, y] = await Promise.all([a, b].map((s) => crypto.subtle.digest('SHA-256', enc.encode(s))));
  return crypto.subtle.timingSafeEqual(x, y);
}

function json(obj, status) {
  return new Response(JSON.stringify(obj), { status, headers: { 'Content-Type': 'application/json; charset=utf-8' } });
}
