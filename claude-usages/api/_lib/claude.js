// Port of `ClaudeService.fetchLiveLimits` + `QuotaData` decoding from the
// BurnTracker macOS app. This runs server-side because the browser cannot set a
// `Cookie` header and claude.ai's private API sends no CORS headers.
//
// The dual snake_case/camelCase handling is deliberate and must be preserved:
// the upstream private API's field naming is not guaranteed.

const USER_AGENT =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

const pick = (obj, ...keys) => {
  for (const k of keys) {
    if (obj && obj[k] !== undefined && obj[k] !== null) return obj[k];
  }
  return undefined;
};

const num = (v) => {
  const n = typeof v === 'string' ? Number(v) : v;
  return typeof n === 'number' && Number.isFinite(n) ? n : undefined;
};

/** One rate-limit window (`five_hour` / `fiveHour`). */
function usageWindow(raw) {
  if (!raw || typeof raw !== 'object') return null;
  return {
    utilization: num(raw.utilization) ?? 0,
    resetsAt: pick(raw, 'resets_at', 'resetsAt') ?? null,
  };
}

/** The purchased-credit ("extra usage") block. Amounts are in minor units. */
function extraUsage(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const used = num(pick(raw, 'used_credits', 'usedCredits'));
  const limit = num(pick(raw, 'monthly_limit', 'monthlyLimit'));
  const utilization = num(raw.utilization);
  return {
    isEnabled: Boolean(pick(raw, 'is_enabled', 'isEnabled')),
    utilization: utilization ?? null,
    usedCredits: used ?? null,
    monthlyLimit: limit ?? null,
    currency: raw.currency ?? null,
    decimalPlaces: num(pick(raw, 'decimal_places', 'decimalPlaces')) ?? null,
    spendLimitReached: Boolean(pick(raw, 'spend_limit_reached', 'spendLimitReached')),
  };
}

/**
 * One entry of the newer self-describing `limits` array. Model-scoped weekly
 * caps live only here — the legacy `seven_day_opus`/`seven_day_sonnet` keys now
 * always come back null, so they are not a substitute.
 */
function rateLimitEntry(raw) {
  const model = raw?.scope?.model;
  const name = pick(model || {}, 'display_name', 'displayName');
  return {
    kind: raw?.kind ?? '',
    group: raw?.group ?? null,
    percent: num(raw?.percent) ?? 0,
    resetsAt: pick(raw || {}, 'resets_at', 'resetsAt') ?? null,
    modelName: name ? String(name) : null,
    isActive: Boolean(pick(raw || {}, 'is_active', 'isActive')),
  };
}

/** Normalizes the `/usage` payload into the shape the dashboard renders. */
export function normalizeQuota(payload) {
  const limits = Array.isArray(payload?.limits) ? payload.limits.map(rateLimitEntry) : [];
  return {
    fiveHour: usageWindow(pick(payload, 'five_hour', 'fiveHour')),
    sevenDay: usageWindow(pick(payload, 'seven_day', 'sevenDay')),
    extraUsage: extraUsage(pick(payload, 'extra_usage', 'extraUsage')),
    limits,
    // Match on `scope.model.display_name` rather than hard-coding a model, so a
    // newly scoped model surfaces on its own. Empty on plans with no such cap —
    // never synthesize a 0% bar for a cap the account does not have.
    modelWeeklyLimits: limits.filter(
      (e) => e.modelName && (e.group === 'weekly' || e.kind.startsWith('weekly')),
    ),
  };
}

function request(url, sessionKey) {
  return fetch(url, {
    headers: {
      Cookie: `sessionKey=${sessionKey}`,
      'User-Agent': USER_AGENT,
      Accept: 'application/json',
    },
    redirect: 'manual',
    signal: AbortSignal.timeout(15000),
  });
}

/**
 * Resolves the first organization, then fetches its rate-limit payload.
 * Returns `{ ok: true, quota }` or `{ ok: false, error }` — never throws, so a
 * single expired key degrades to one card's error state.
 */
export async function fetchLiveLimits(sessionKey) {
  if (!sessionKey) return { ok: false, error: 'Session key is empty.' };

  try {
    const orgsRes = await request('https://claude.ai/api/organizations', sessionKey);
    if (orgsRes.status === 401 || orgsRes.status === 403) {
      return { ok: false, error: 'Unauthorized. The sessionKey might be invalid or expired.' };
    }
    if (!orgsRes.ok) return { ok: false, error: `Server returned status ${orgsRes.status}` };

    const orgs = await orgsRes.json().catch(() => []);
    const orgId = Array.isArray(orgs) ? orgs[0]?.uuid : undefined;
    if (!orgId) return { ok: false, error: 'No organizations found on this account.' };

    const usageRes = await request(
      `https://claude.ai/api/organizations/${orgId}/usage`,
      sessionKey,
    );
    if (!usageRes.ok) return { ok: false, error: `Server returned status ${usageRes.status}` };

    return { ok: true, quota: normalizeQuota(await usageRes.json()) };
  } catch (err) {
    return { ok: false, error: `Connection failed: ${err?.message || err}` };
  }
}

/** The account email from `/api/bootstrap`. A nice-to-have; never blocks quota. */
export async function fetchAccountEmail(sessionKey) {
  try {
    const res = await request('https://claude.ai/api/bootstrap', sessionKey);
    if (!res.ok) return null;
    const json = await res.json();
    const email = json?.account?.email_address;
    return email || null;
  } catch {
    return null;
  }
}
