// Fetches one Claude account's live quota.
//
// POST { id }          — use a host-configured key (never leaves the server)
// POST { sessionKey }  — BYO-key mode: the browser holds the key and sends it
//                        over HTTPS for this request only; it is never stored.
import { sendJSON, readJSONBody, serverAccounts, maskKey } from './_lib/http.js';
import { fetchLiveLimits, fetchAccountEmail } from './_lib/claude.js';

export default async function handler(req, res) {
  if (req.method !== 'POST') return sendJSON(res, 405, { error: 'Method not allowed' });

  const body = await readJSONBody(req);
  let sessionKey = typeof body.sessionKey === 'string' ? body.sessionKey.trim() : '';
  let label = typeof body.label === 'string' ? body.label.trim() : '';

  if (body.id) {
    const account = serverAccounts().find((a) => a.id === body.id);
    if (!account) return sendJSON(res, 404, { error: 'Unknown account.' });
    sessionKey = account.sessionKey;
    label = account.label;
  } else if (sessionKey && process.env.ALLOW_CLIENT_KEYS === 'false') {
    return sendJSON(res, 403, { error: 'This deployment only serves host-configured accounts.' });
  }

  if (!sessionKey) return sendJSON(res, 400, { error: 'Session key is empty.' });

  const result = await fetchLiveLimits(sessionKey);
  if (!result.ok) {
    return sendJSON(res, 200, { status: 'error', label, masked: maskKey(sessionKey), error: result.error });
  }

  const email = await fetchAccountEmail(sessionKey);
  sendJSON(res, 200, {
    status: 'online',
    label,
    email,
    masked: maskKey(sessionKey),
    quota: result.quota,
    fetchedAt: new Date().toISOString(),
  });
}
