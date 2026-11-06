// How many phones use TABOR a day, and on which build, without keeping anything that points
// back at a person. Each counted request leaves one row in Workers Analytics Engine (kept
// about three months): the build, what was asked for, and a phone tag.
//
// The tag is an HMAC of the IP and user agent, keyed with a secret plus Warsaw's date, so it
// changes every midnight and can't be worked back to an IP, or matched across days, by anyone
// without STATS_SECRET (a Worker secret nobody keeps a copy of). It's approximate: phones
// behind one carrier NAT on the same iOS build count once, and a phone moving from Wi-Fi to
// mobile data counts twice.
//
// Only the app counts (its user agent starts "Tabor/"), and the feed only on type=1, since the
// app always asks for both kinds together: one row per poll keeps well inside the free plan's
// 100,000 rows a day.

export function count(request, env, ctx, what) {
  if (!env.STATS || !env.STATS_SECRET) return;
  const agent = request.headers.get('User-Agent') ?? '';
  const build = agent.match(/^Tabor\/(\d+)/)?.[1];
  if (!build) return;
  const ip = request.headers.get('CF-Connecting-IP') ?? '';
  // Warsaw's date goes in the row too, so a day's phones are counted over exactly the day their
  // tags lasted (a UTC day would straddle two tags and count late-night phones twice).
  const date = new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Warsaw' });
  ctx.waitUntil(tag(env.STATS_SECRET, date, `${ip} ${agent}`).then((phone) => {
    env.STATS.writeDataPoint({ indexes: [phone], blobs: [build, what, date], doubles: [1] });
  }));
}

async function tag(secret, date, text) {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey('raw', enc.encode(`${secret} ${date}`), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = new Uint8Array(await crypto.subtle.sign('HMAC', key, enc.encode(text)));
  return [...mac.slice(0, 12)].map((b) => b.toString(16).padStart(2, '0')).join('');
}
