// Port of `CommandCodeService` from the BurnTracker macOS app.
//
// Command Code bills in **credits** (dollars against a monthly plan allowance)
// with optional 5-hour / weekly request windows on top, so it has its own shape
// rather than reusing the Claude quota model.
//
// Two things here are ports of the `cmd` CLI's own internals and must be kept
// in step with it: the per-plan allowance table (the API returns a `planId` but
// never the allowance) and the `project()` credit math — in particular the
// `max(planAllowance, monthlyRemaining)` term, which is what makes the reported
// percentage match `cmd`'s own `/usage` view.

const API_BASE = 'https://api.commandcode.ai';

const PLAN_CREDITS = {
  'individual-go': 10,
  'individual-pro': 30,
  'individual-provider': 15,
  'individual-max': 150,
  'individual-ultra': 300,
  'teams-pro': 40,
};

const PLAN_NAMES = {
  'individual-go': 'Go',
  'individual-pro': 'Pro',
  'individual-provider': 'Provider',
  'individual-max': 'Max',
  'individual-ultra': 'Ultra',
  'teams-pro': 'Teams Pro',
};

const asNumber = (v) => {
  const n = typeof v === 'string' ? Number(v) : v;
  return typeof n === 'number' && Number.isFinite(n) ? n : undefined;
};

/** Resolves a plan id to its friendly name + allowance by longest known prefix. */
function planInfo(planId) {
  if (!planId) return null;
  const normalized = String(planId).toLowerCase().replaceAll('_', '-');
  const key = Object.keys(PLAN_CREDITS)
    .sort((a, b) => b.length - a.length)
    .find((k) => normalized.startsWith(k));
  return key ? { name: PLAN_NAMES[key] || key, monthlyCredits: PLAN_CREDITS[key] } : null;
}

/** One `windowLimits` entry. `resetAt` is epoch ms; `0` means not started. */
function windowLimit(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const cap = asNumber(raw.cap) ?? 0;
  if (cap <= 0) return null;
  const used = Math.max(0, asNumber(raw.used) ?? 0);
  const resetMillis = asNumber(raw.resetAt) ?? 0;
  return {
    used,
    cap,
    exceeded: Boolean(raw.exceeded),
    resetAt: resetMillis > 0 ? new Date(resetMillis).toISOString() : null,
    usedPct: Math.round(Math.min(100, Math.max(0, (used / cap) * 100))),
  };
}

function project(creditsJSON, subscription, summary) {
  const credits = creditsJSON?.credits || {};
  const amount = (field) => Math.max(0, asNumber(credits[field]) ?? 0);

  const monthly = amount('monthlyCredits');
  const purchased = amount('purchasedCredits');
  const free = amount('freeCredits');
  const remaining = monthly + purchased + free;
  const spent = Math.max(0, asNumber(summary?.totalCost) ?? 0);

  const status = subscription?.status ?? null;
  const plan = planInfo(subscription?.planId);

  // The plan allowance only counts while the subscription is active; otherwise
  // the pool is just what has been spent plus what is left.
  const allowance = status === 'active' ? plan?.monthlyCredits : undefined;
  const pool =
    allowance !== undefined ? Math.max(allowance, monthly) + purchased + free : spent + remaining;

  const hasCreditsInfo = remaining > 0 || spent > 0;
  const creditsUsedPct =
    hasCreditsInfo && pool > 0 ? Math.round(Math.min(100, ((pool - remaining) / pool) * 100)) : 0;

  const windows = creditsJSON?.windowLimits;
  // `limited: false` means the plan enforces no request windows at all.
  const limited = Boolean(windows?.limited);

  return {
    planName: plan?.name ?? null,
    planStatus: status,
    periodEnd: subscription?.currentPeriodEnd ?? null,
    monthlyRemaining: monthly,
    purchasedRemaining: purchased,
    freeRemaining: free,
    totalRemaining: remaining,
    totalSpent: spent,
    requestCount: asNumber(summary?.totalCount) ?? null,
    totalPool: pool,
    hasCreditsInfo,
    creditsUsedPct,
    fiveHour: limited ? windowLimit(windows?.fiveHour) : null,
    weekly: limited ? windowLimit(windows?.weekly) : null,
  };
}

/** GETs a JSON endpoint with the CLI's bearer auth; nil-valued params omitted. */
async function get(path, apiKey, params = {}) {
  const url = new URL(API_BASE + path);
  for (const name of Object.keys(params).sort()) {
    const value = params[name];
    if (value !== undefined && value !== null) url.searchParams.set(name, value);
  }
  try {
    const res = await fetch(url, {
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      signal: AbortSignal.timeout(15000),
    });
    if (!res.ok) return null;
    return await res.json();
  } catch {
    return null;
  }
}

/**
 * Mirrors the CLI's `fetchUsageData` sequence: whoami → credits + subscriptions
 * in parallel → usage summary scoped to the current billing period. `orgId` is
 * omitted for personal accounts (`org: null`).
 */
export async function fetchCommandCodeQuota(apiKey) {
  if (!apiKey) return { ok: false, error: 'No Command Code API key configured.' };

  const whoami = await get('/alpha/whoami', apiKey);
  if (!whoami) return { ok: false, error: 'Unauthorized. Run `cmd login` and copy the new key.' };

  const email = whoami?.user?.email ?? null;
  const orgId = whoami?.org?.id ?? null;

  const [creditsJSON, subscriptionJSON] = await Promise.all([
    get('/alpha/billing/credits', apiKey, { orgId }),
    get('/alpha/billing/subscriptions', apiKey, { orgId }),
  ]);

  // Credits carry the balances and the window limits — without them there is
  // nothing to show, so treat a failure here as a failed sync.
  if (!creditsJSON) return { ok: false, error: 'Could not read credit balances.' };

  const subscription = subscriptionJSON?.data ?? null;
  const summary = await get('/alpha/usage/summary', apiKey, {
    orgId,
    since: subscription?.currentPeriodStart ?? null,
  });

  return { ok: true, email, quota: project(creditsJSON, subscription, summary) };
}
