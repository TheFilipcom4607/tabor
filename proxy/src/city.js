// Warsaw's live vehicle feed, for the proxy (index.js).

// The city is moving its open data from api.um.warszawa.pl to dane.um.warszawa.pl and will
// switch the old one off. The new one comes first; the old one covers for it until then.
const DANE = 'https://dane.um.warszawa.pl/api/action/get_ztm_lokalizacja_pojazdow';
const OLD = 'https://api.um.warszawa.pl/api/action/busestrams_get/';
const OLD_RESOURCE = 'f2e5503e-927d-4ad3-9500-4ab9e55deb59';
// The city answers in well under a second; when it doesn't, it tends to hang for minutes.
// Two tries of this still finish before the app gives up at 20 s.
const TIMEOUT_MS = 5_000;

// Both return the reply's text, or null if the call failed. The text is checked only at its
// ends, never parsed: parsing ~180 KB and writing it out again was most of the proxy's CPU,
// and the free plan allows 10 ms a call. A reply cut off mid-way still fails the check.

async function daneText(type, token) {
  if (!token) return null;
  try {
    const res = await fetch(DANE, {
      method: 'POST',
      headers: { Authorization: token, 'Content-Type': 'application/json' },
      body: JSON.stringify({ type: Number(type) }),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    // The new service answers a bad token with a 500, and sends a bare list.
    if (!res.ok) return null;
    const text = (await res.text()).trim();
    return text.startsWith('[') && text.endsWith(']') ? text : null;
  } catch {
    return null;
  }
}

async function oldText(type, key) {
  if (!key) return null;
  const url = `${OLD}?resource_id=${OLD_RESOURCE}&type=${type}&apikey=${encodeURIComponent(key)}`;
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(TIMEOUT_MS) });
    if (!res.ok) return null;
    // Errors come back as 200 with a message in `result` instead of the list.
    const text = (await res.text()).trim();
    return /^\{\s*"result"\s*:\s*\[/.test(text) && text.endsWith('}') ? text : null;
  } catch {
    return null;
  }
}

// The body phones get, in the old service's shape {"result": [...]} whichever service
// answered: the new one's bare list is wrapped as text, the old one's reply already is it.
export async function fetchFeed(type, env) {
  const dane = await daneText(type, env.DANE_TOKEN);
  if (dane) return { body: `{"result":${dane}}`, source: 'dane' };
  const old = await oldText(type, env.UM_KEY);
  return old ? { body: old, source: 'old' } : null;
}
