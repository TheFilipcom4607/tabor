// Remarks on vehicles from czynaczas.pl's partner API (Marcin Bittel, agreed 2026-11-09).
//
//   PUT /v1/czynaczas          the nightly upload from the fleet Action (token-gated)
//   GET /v1/czynaczas/meta     its ETag and the special-vehicles list, for that Action (token-gated)
//   PUT /v1/czynaczas/vehicles brand, model and year per vehicle, from the same nightly run (token-gated)
//   GET /v1/czynaczas/vehicles the same, for the Actions' issues: trial buses, types with no model
//   GET /v1/remarks/bus/5869   one vehicle's remark, for the app's vehicle page
//
// His terms: none of his data sits in the public repo, and nobody gets all of it in one go.
// So the Action fetches it with the key and PUTs here only what the app or the Actions need:
// the remarks, the special-vehicles list and each vehicle's brand, model and year. The bot's
// issues may name a single vehicle's model or a special entry, credited (he's fine with that);
// the remarks never leave here but one at a time. Phones ask for one vehicle at a time, under
// their own limit (REMARKS_PER_IP) on top of the app's, and there is no public endpoint that
// lists anything. Every answer carries the credit he asked for.
//
// Each remark is kept as {pl, en}. The English is written by hand (scripts/czynaczas.py sends it
// from a file kept out of git) and survives uploads without it, such as the nightly Action's,
// for as long as the Polish it translates stays the same.

const KEY = 'czynaczas';
const KINDS = { bus: '3', tram: '0' };
const SOURCE = { source: 'czynaczas.pl', url: 'https://czynaczas.pl' };
// A normal upload has a few dozen remarks. Far fewer means a broken reply: keep yesterday's.
const MIN_REMARKS = 5;
const MAX_BYTES = 200_000;
// About 3100 vehicles of brand, model and year come to some 250 KB.
const MAX_VEHICLE_BYTES = 1_000_000;
// Parsed remarks, kept for this isolate's life: a few KB, but a phone opens many pages in a row.
const MEMORY_MS = 10 * 60_000;

let memo = null;

export async function putCzynaczas(request, env) {
  if (!(await authorized(request, env))) return json({ result: 'Unauthorized' }, 401);
  const text = await request.text();
  if (text.length > MAX_BYTES) return json({ result: 'Too big: send only the remarks and special vehicles' }, 413);
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    return json({ result: 'Not JSON' }, 400);
  }
  const { etag, remarks, special } = body ?? {};
  const entries = isObject(remarks) ? Object.entries(remarks).map(([k, v]) => [k, typeof v === 'string' ? { pl: v } : v]) : null;
  if (typeof etag !== 'string' || !entries || !Array.isArray(special)
      || !entries.every(([k, v]) => /^[03]\/[\w-]+$/.test(k) && isObject(v) && typeof v.pl === 'string'
                                    && (v.en === undefined || typeof v.en === 'string'))) {
    return json({ result: 'Expected {etag, remarks: {"3/5869": "…" or {pl, en}}, special: [...]}' }, 400);
  }
  const count = entries.length;
  if (count < MIN_REMARKS) return json({ result: `Only ${count} remarks: keeping the old ones` }, 422);
  const old = (await env.ROUTES.get(KEY, { type: 'json' })) ?? {};
  const merged = {};
  for (const [k, { pl, en }] of entries) {
    const before = typeof old[k] === 'string' ? { pl: old[k] } : old[k];
    const english = en ?? (before?.pl === pl ? before.en : undefined);
    merged[k] = english ? { pl, en: english } : { pl };
  }
  const english = Object.values(merged).filter((v) => v.en).length;
  // How many vehicles the sync sent to /v1/czynaczas/vehicles just before: none means the next
  // sync must fetch the whole reply rather than take a 304.
  const vehicles = Number.isInteger(body.vehicles) ? body.vehicles : 0;
  const meta = { etag, special, remarks: count, english, vehicles, updated: new Date().toISOString() };
  // Remarks first: a reader that sees the new ETag must find the remarks it names.
  await env.ROUTES.put(KEY, JSON.stringify(merged));
  await env.ROUTES.put(`${KEY}:meta`, JSON.stringify(meta));
  memo = null;
  // Counts only: the logs are no place for his data either.
  console.log(`czynaczas: ${count} remarks (${english} in English), ${special.length} special vehicles`);
  return json({ result: 'ok', remarks: count, english, special: special.length }, 200);
}

// Stored as sent, never parsed: 250 KB of JSON would eat much of the free plan's 10 ms of CPU, and
// only the Actions, with the token, write or read it.
export async function czynaczasVehicles(request, env) {
  if (!(await authorized(request, env))) return json({ result: 'Unauthorized' }, 401);
  if (request.method === 'GET') {
    const text = await env.ROUTES.get(`${KEY}:vehicles`);
    return text ? new Response(text, { headers: { 'Content-Type': 'application/json; charset=utf-8' } })
      : json({ result: 'Nothing uploaded yet' }, 404);
  }
  if (request.method !== 'PUT') return json({ result: 'GET or PUT only' }, 405);
  const text = await request.text();
  if (text.length > MAX_VEHICLE_BYTES) return json({ result: 'Too big' }, 413);
  if (!/^\{"[03]\//.test(text) || !text.endsWith('}')) return json({ result: 'Expected {"3/5869": {...}, ...}' }, 400);
  await env.ROUTES.put(`${KEY}:vehicles`, text);
  console.log(`czynaczas: vehicles uploaded (${text.length} bytes)`);
  return json({ result: 'ok', bytes: text.length }, 200);
}

export async function getCzynaczasMeta(request, env) {
  if (!(await authorized(request, env))) return json({ result: 'Unauthorized' }, 401);
  const meta = await env.ROUTES.get(`${KEY}:meta`, { type: 'json' });
  return meta ? json(meta, 200) : json({ result: 'Nothing uploaded yet' }, 404);
}

// /v1/remarks/bus/5869 → {remark, remarkEn, source, url}: the Polish and its English (null until
// translated), or remark null when he has none for it.
export async function getRemark(request, env, url) {
  if (request.method !== 'GET') return json({ result: 'GET only' }, 405);
  const ip = request.headers.get('CF-Connecting-IP') ?? 'unknown';
  const { success } = await env.REMARKS_PER_IP.limit({ key: ip });
  if (!success) return json({ result: 'Too many requests' }, 429);
  const m = url.pathname.match(/^\/v1\/remarks\/(bus|tram)\/(\d{1,6})$/);
  if (!m) return json({ result: 'Ask for one vehicle: /v1/remarks/bus/5869 or /v1/remarks/tram/1252' }, 400);
  const remarks = await load(env);
  if (!remarks) return json({ result: 'No remarks yet' }, 503);
  const entry = remarks[`${KINDS[m[1]]}/${Number(m[2])}`];
  // Uploads before 2026-11-09 evening stored the Polish alone.
  const { pl = null, en = null } = typeof entry === 'string' ? { pl: entry } : entry ?? {};
  // A remark changes rarely; a day's copy on the phone is plenty.
  return new Response(JSON.stringify({ remark: pl, remarkEn: en, ...SOURCE }), {
    headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'private, max-age=86400' },
  });
}

async function load(env) {
  if (memo && Date.now() - memo.at < MEMORY_MS) return memo.remarks;
  const remarks = await env.ROUTES.get(KEY, { type: 'json', cacheTtl: 600 });
  if (remarks) memo = { remarks, at: Date.now() };
  return remarks;
}

const isObject = (x) => x !== null && typeof x === 'object' && !Array.isArray(x);

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
