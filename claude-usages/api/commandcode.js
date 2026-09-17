// Fetches the Command Code (`cmd` CLI) quota.
//
// The key comes from the host's COMMAND_CODE_API_KEY, or from the browser in
// BYO-key mode — the value of "apiKey" in ~/.commandcode/auth.json.
import { sendJSON, readJSONBody, maskKey } from './_lib/http.js';
import { fetchCommandCodeQuota } from './_lib/commandcode.js';

export default async function handler(req, res) {
  if (req.method !== 'POST') return sendJSON(res, 405, { error: 'Method not allowed' });

  const body = await readJSONBody(req);
  const clientKey = typeof body.apiKey === 'string' ? body.apiKey.trim() : '';
  if (clientKey && process.env.ALLOW_CLIENT_KEYS === 'false') {
    return sendJSON(res, 403, { error: 'This deployment only serves host-configured accounts.' });
  }

  const apiKey = clientKey || process.env.COMMAND_CODE_API_KEY || '';
  if (!apiKey) return sendJSON(res, 400, { error: 'No Command Code API key configured.' });

  const result = await fetchCommandCodeQuota(apiKey);
  if (!result.ok) {
    return sendJSON(res, 200, { status: 'error', masked: maskKey(apiKey), error: result.error });
  }

  sendJSON(res, 200, {
    status: 'online',
    email: result.email,
    masked: maskKey(apiKey),
    quota: result.quota,
    fetchedAt: new Date().toISOString(),
  });
}
