// node src/track.test.mjs
// The Durable Object with its storage, the feed and Apple's push servers faked, for what
// can't be seen without them: the phone writing while a tick is still pushing.
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { register } from 'node:module';

// Node has no 'cloudflare:workers': hand track.js a bare DurableObject to extend.
const base = 'export class DurableObject { constructor(ctx, env) { this.ctx = ctx; this.env = env; } }';
register(`data:text/javascript,${encodeURIComponent(`
  export async function resolve(specifier, context, next) {
    return specifier === 'cloudflare:workers'
      ? { url: 'data:text/javascript,${encodeURIComponent(base)}', shortCircuit: true }
      : next(specifier, context);
  }`)}`);
const { Tracker } = await import('./track.js');

function encode(points) {
  let out = '', pLat = 0, pLon = 0;
  const put = (d) => { let v = d < 0 ? ~(d << 1) : d << 1; while (v >= 0x20) { out += String.fromCharCode((0x20 | (v & 0x1f)) + 63); v >>= 5; } out += String.fromCharCode(v + 63); };
  for (const [lat, lon] of points) { const a = Math.round(lat * 1e5), b = Math.round(lon * 1e5); put(a - pLat); put(b - pLon); pLat = a; pLon = b; }
  return out;
}

function storage() {
  const rows = new Map();
  let alarm = null;
  return {
    rows,
    async get(k) { return rows.get(k); },
    async put(k, v) { rows.set(k, structuredClone(v)); },
    async delete(k) { rows.delete(k); },
    async list({ prefix }) { return new Map([...rows].filter(([k]) => k.startsWith(prefix)).map(([k, v]) => [k, structuredClone(v)])); },
    async getAlarm() { return alarm; },
    async setAlarm(t) { alarm = t; },
  };
}

// A throwaway key in the .p8's shape, so the provider token signs.
const pair = await webcrypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign']);
const pkcs8 = Buffer.from(await webcrypto.subtle.exportKey('pkcs8', pair.privateKey)).toString('base64');
const env = { APNS_KEY: `-----BEGIN PRIVATE KEY-----\n${pkcs8}\n-----END PRIVATE KEY-----`, APNS_KEY_ID: 'K', APNS_TEAM_ID: 'T' };

// Bus 1998 on a straight street east along 52.23, reporting now; your stop 1.3 km along it.
const warsaw = (d) => new Intl.DateTimeFormat('sv-SE', { timeZone: 'Europe/Warsaw', dateStyle: 'short', timeStyle: 'medium' }).format(d);
const state = { lon: 21.001, pushes: [], status: 200, meanwhile: null };
globalThis.fetch = async (url, init) => {
  if (String(url).includes('/v1/vehicles')) {
    return new Response(JSON.stringify({ result: [{ VehicleNumber: '1998', Lat: 52.23, Lon: state.lon, Time: warsaw(new Date()), Lines: '164' }] }));
  }
  state.pushes.push({ token: String(url).split('/').pop(), aps: JSON.parse(init.body).aps });
  const meanwhile = state.meanwhile;
  state.meanwhile = null;
  await meanwhile?.();
  return new Response(state.status === 200 ? '' : '{"reason":"TooManyRequests"}', { status: state.status });
};
console.log = () => {};

const A = 'a'.repeat(64), B = 'b'.repeat(64);
const follow = {
  id: 'abc', token: A, type: '1', number: '1998', distance: 1300,
  path: encode(Array.from({ length: 61 }, (_, i) => [52.23, 21.0 + i * 0.0005])),
  stops: [{ n: 'Syta', lat: 52.23, lon: 21.01 }, { n: 'Vogla', lat: 52.23, lon: 21.02 }],
  target: { n: 'Vogla', lat: 52.23, lon: 21.02 },
};
const call = (tracker, body, method = 'POST') => tracker.fetch(new Request('https://x/v1/track', { method, body: JSON.stringify(body) }));
const fresh = async () => {
  Object.assign(state, { lon: 21.001, pushes: [], status: 200, meanwhile: null });
  const store = storage(), tracker = new Tracker({ storage: store }, env);
  assert.equal((await call(tracker, follow)).status, 200);
  return { store, tracker };
};

// Caught (or dismissed) while a tick was pushing: it stays gone, rather than being written back.
{
  const { store, tracker } = await fresh();
  state.meanwhile = () => call(tracker, { id: 'abc' }, 'DELETE');
  await tracker.alarm();
  assert.equal(store.rows.has('f:abc'), false);
}

// A new token while a tick was pushing: kept, and the next tick says it all again to that one.
{
  const { store, tracker } = await fresh();
  state.meanwhile = () => call(tracker, { id: 'abc', token: B });
  await tracker.alarm();
  assert.equal(store.rows.get('f:abc').token, B);
  assert.equal(store.rows.get('f:abc').sent, null);
  await tracker.alarm();
  assert.equal(state.pushes.at(-1).token, B);
  assert.equal(store.rows.get('f:abc').sent.phase, 'coming');
}

// Apple turning a push down doesn't count as sent: the arrival, alert and all, goes again.
{
  const { store, tracker } = await fresh();
  await tracker.alarm();
  Object.assign(state, { lon: 21.0199, status: 429 });
  await tracker.alarm();
  assert.equal(state.pushes.at(-1).aps['content-state'].phase, 'here');
  assert.equal(store.rows.get('f:abc').sent.phase, 'coming');
  state.status = 200;
  await tracker.alarm();
  assert.ok(state.pushes.at(-1).aps.alert);
  assert.equal(store.rows.get('f:abc').sent.phase, 'here');
  // Once it's through, standing at the stop is nothing new.
  const sent = state.pushes.length;
  await tracker.alarm();
  assert.equal(state.pushes.length, sent);
}

process.stdout.write('tracker: ok\n');
