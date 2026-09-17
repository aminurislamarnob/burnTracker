// Small helpers shared by the serverless endpoints. Files under `api/_lib/`
// start with an underscore, so Vercel treats them as library code rather than
// routes.

/** Sends a JSON response, never cached (responses carry live quota + keys). */
export function sendJSON(res, status, payload) {
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store, max-age=0');
  res.status(status).send(JSON.stringify(payload));
}

/** Parses a JSON request body, tolerating an already-parsed `req.body`. */
export async function readJSONBody(req) {
  if (req.body && typeof req.body === 'object') return req.body;
  if (typeof req.body === 'string' && req.body.length) {
    try { return JSON.parse(req.body); } catch { return {}; }
  }
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  if (!chunks.length) return {};
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { return {}; }
}

/**
 * Server-side Claude accounts from `CLAUDE_SESSION_KEYS`. Accepts either a JSON
 * array of `{ label, sessionKey }` or a compact `label=key` list separated by
 * commas/newlines, so a single key can be pasted without JSON quoting.
 */
export function serverAccounts() {
  const raw = (process.env.CLAUDE_SESSION_KEYS || '').trim();
  if (!raw) return [];

  let entries = [];
  if (raw.startsWith('[')) {
    try {
      entries = JSON.parse(raw)
        .map((e) => ({ label: String(e.label || '').trim(), sessionKey: String(e.sessionKey || e.key || '').trim() }));
    } catch {
      entries = [];
    }
  } else {
    entries = raw
      .split(/[,\n]/)
      .map((pair) => pair.trim())
      .filter(Boolean)
      .map((pair) => {
        const at = pair.indexOf('=');
        if (at === -1) return { label: 'Claude', sessionKey: pair };
        return { label: pair.slice(0, at).trim(), sessionKey: pair.slice(at + 1).trim() };
      });
  }

  return entries
    .filter((e) => e.sessionKey)
    .map((e, i) => ({ id: `srv${i}`, label: e.label || `Account ${i + 1}`, sessionKey: e.sessionKey }));
}

/** Masks a session key for display — never return a whole key to the browser. */
export function maskKey(key) {
  if (!key) return '';
  return key.length <= 12 ? '••••' : `${key.slice(0, 8)}…${key.slice(-4)}`;
}

export function refreshSeconds() {
  const n = Number(process.env.REFRESH_SECONDS);
  return Number.isFinite(n) && n >= 30 ? Math.round(n) : 300;
}
