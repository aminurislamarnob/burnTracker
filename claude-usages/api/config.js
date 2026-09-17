// What the browser needs to know before it renders: which accounts the host has
// configured (labels only — keys stay server-side), whether a Command Code key
// is present, and the auto-refresh interval.
import { sendJSON, serverAccounts, maskKey, refreshSeconds } from './_lib/http.js';

export default function handler(req, res) {
  if (req.method !== 'GET') return sendJSON(res, 405, { error: 'Method not allowed' });

  sendJSON(res, 200, {
    accounts: serverAccounts().map((a) => ({ id: a.id, label: a.label, masked: maskKey(a.sessionKey) })),
    commandCode: Boolean(process.env.COMMAND_CODE_API_KEY),
    refreshSeconds: refreshSeconds(),
    // Whether the browser is allowed to add its own keys (BYO-key mode).
    allowClientKeys: process.env.ALLOW_CLIENT_KEYS !== 'false',
  });
}
