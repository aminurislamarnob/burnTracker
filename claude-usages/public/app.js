// Claude Usage — single-page dashboard.
//
// Rendering mirrors BurnTracker's cards: a header, a hairline, then one compact
// quota row per limit (5-hour session, all-models weekly, each model-scoped
// weekly cap, purchased credits), plus a Command Code credit card.
//
// Keys never reach claude.ai from here directly: the browser cannot set a
// `Cookie` header and the private API sends no CORS headers, so every fetch goes
// through this deployment's own `/api/*` functions.

const STORE = {
  accounts: 'claude-usages:accounts',
  commandCode: 'claude-usages:command-code',
  interval: 'claude-usages:interval',
};

const el = (id) => document.getElementById(id);
const grid = el('grid');

let config = { accounts: [], commandCode: false, refreshSeconds: 300, allowClientKeys: true };
let state = new Map(); // card id -> { kind, label, status, ... }
let timer = null;
let ticker = null;

// ── Storage (best-effort: private windows can throw or come back empty) ─────

function readStore(key, fallback) {
  try {
    const raw = localStorage.getItem(key);
    return raw ? JSON.parse(raw) : fallback;
  } catch {
    return fallback;
  }
}

function writeStore(key, value) {
  try {
    if (value === null) localStorage.removeItem(key);
    else localStorage.setItem(key, JSON.stringify(value));
  } catch {
    /* storage blocked — the dashboard still works for this session */
  }
}

const localAccounts = () => {
  const list = readStore(STORE.accounts, []);
  return Array.isArray(list) ? list : [];
};
const localCommandCodeKey = () => readStore(STORE.commandCode, '') || '';

// ── Formatting (port of TimeFormat.swift) ──────────────────────────────────

function parseDate(value) {
  if (!value) return null;
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? null : d;
}

/** "in 3h 12m" / "Mon 3:00 PM" / "any moment" — matches the app's countdown. */
function timeUntil(value) {
  const target = parseDate(value);
  if (!target) return '--';
  const diff = target.getTime() - Date.now();
  if (diff <= 0) return 'any moment';

  const totalMin = Math.floor(diff / 60000);
  const hrs = Math.floor(totalMin / 60);
  const mins = totalMin % 60;

  if (hrs >= 24) {
    const day = target.toLocaleDateString('en-US', { weekday: 'short' });
    const time = target.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
    return `${day} ${time}`;
  }
  if (hrs > 0) return `in ${hrs}h ${mins}m`;
  return `in ${mins}m`;
}

/** The compact variant used on quota rows: "in 6d 13h", "in 5h", "in 45m". */
function compactReset(value) {
  const target = parseDate(value);
  if (!target) return '—';
  const diff = target.getTime() - Date.now();
  if (diff <= 0) return 'any moment';
  const totalMin = Math.floor(diff / 60000);
  const days = Math.floor(totalMin / 1440);
  const hrs = Math.floor((totalMin % 1440) / 60);
  const mins = totalMin % 60;
  if (days >= 1) return hrs > 0 ? `in ${days}d ${hrs}h` : `in ${days}d`;
  if (hrs >= 1) return `in ${hrs}h`;
  return `in ${mins}m`;
}

/** "just now" / "3m ago" / "2h ago" — the card's "Updated …" line. */
function relative(value) {
  const date = parseDate(value);
  if (!date) return '—';
  const secs = Math.max(0, (Date.now() - date.getTime()) / 1000);
  if (secs < 45) return 'just now';
  const mins = Math.floor(secs / 60);
  if (mins < 60) return `${Math.max(1, mins)}m ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  return `${Math.floor(hrs / 24)}d ago`;
}

const CURRENCY = { USD: '$', EUR: '€', GBP: '£', JPY: '¥' };

/** "$0.08 of $100.00" — extra-usage amounts arrive in minor units. */
function amountLabel(extra) {
  if (extra.usedCredits === null || extra.monthlyLimit === null) return null;
  const symbol = CURRENCY[(extra.currency || 'USD').toUpperCase()] ?? `${extra.currency} `;
  const places = extra.decimalPlaces ?? 2;
  const divisor = 10 ** places;
  const fmt = (v) => (v / divisor).toFixed(Math.max(0, places));
  return `${symbol}${fmt(extra.usedCredits)} of ${symbol}${fmt(extra.monthlyLimit)}`;
}

const money = (v) => `$${(Number(v) || 0).toFixed(2)}`;
const pct = (v) => Math.round(Math.min(100, Math.max(0, Number(v) || 0)));

/** Used-quota semantics: neutral base tint, warns as usage climbs high. */
function usedTint(percent, base) {
  if (percent >= 95) return 'var(--error)';
  if (percent >= 80) return 'var(--warning)';
  return base;
}

function extraUsagePct(extra) {
  if (extra.utilization !== null && extra.utilization !== undefined) return Math.round(extra.utilization);
  if (extra.usedCredits && extra.monthlyLimit) return Math.round((extra.usedCredits / extra.monthlyLimit) * 100);
  return 0;
}

// ── Rendering ──────────────────────────────────────────────────────────────

const escape = (s) =>
  String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

function quotaRow({ title, percent, tint, left, right, chip }) {
  const p = pct(percent);
  return `
    <div>
      <div class="row-title">
        <span>${escape(title)}</span>
        ${chip ? `<span class="row-chip">${escape(chip)}</span>` : ''}
      </div>
      <div class="bar"><span style="width:${p}%;background:${usedTint(p, tint)}"></span></div>
      <div class="row-foot"><span class="left">${escape(left)}</span><span class="right">${escape(right)}</span></div>
    </div>`;
}

function cardHead(card) {
  const statusLine =
    card.status === 'syncing' && !card.quota ? 'Updating…'
    : card.status === 'error' ? 'Update failed'
    : `Updated ${relative(card.fetchedAt)}`;

  return `
    <div class="card-head">
      <span class="badge" data-provider="${card.kind}">${card.kind === 'claude' ? 'C' : '&gt;_'}</span>
      <div class="head-text">
        <div class="head-title">
          <h2>${escape(card.label)}</h2>
          <span class="head-detail">${escape(card.detail || '')}</span>
        </div>
        <p class="head-meta">
          <span>${escape(statusLine)}</span><span class="sep">·</span><span>${card.kind === 'claude' ? 'Claude.ai' : 'Command Code'}</span>
        </p>
      </div>
      <button class="icon-btn" type="button" data-sync="${escape(card.id)}" title="Refresh this card" aria-label="Refresh ${escape(card.label)}">⟳</button>
    </div>
    <div class="divider"></div>`;
}

function claudeBody(card) {
  if (card.status === 'error') {
    return `<div class="notice error"><strong>Sync Failed</strong>${escape(card.error || 'Unauthorized / Invalid Key')}</div>`;
  }
  if (!card.quota) return `<div class="notice">Syncing quotas…</div>`;

  const q = card.quota;
  const sessionPct = Math.round(q.fiveHour?.utilization ?? 0);
  const weeklyPct = Math.round(q.sevenDay?.utilization ?? 0);

  const rows = [
    quotaRow({
      title: 'Current Session (5h)',
      percent: sessionPct,
      tint: 'var(--accent)',
      left: `${sessionPct}% used`,
      right: q.fiveHour?.resetsAt ? `Resets ${compactReset(q.fiveHour.resetsAt)}` : 'Resets periodically',
    }),
    quotaRow({
      title: 'Weekly Limit',
      percent: weeklyPct,
      tint: 'var(--info)',
      left: `${weeklyPct}% used`,
      right: q.sevenDay?.resetsAt ? `Resets ${compactReset(q.sevenDay.resetsAt)}` : 'Resets weekly',
    }),
    // One bar per model-scoped weekly cap; absent entirely on plans without one.
    ...(q.modelWeeklyLimits || []).map((limit) => {
      const p = Math.round(limit.percent);
      return quotaRow({
        title: `${limit.modelName} Weekly Limit`,
        percent: p,
        tint: 'var(--model)',
        left: `${p}% used`,
        right: limit.resetsAt ? `Resets ${compactReset(limit.resetsAt)}` : 'Resets weekly',
      });
    }),
  ];

  if (q.extraUsage?.isEnabled) {
    const p = extraUsagePct(q.extraUsage);
    rows.push(
      quotaRow({
        title: 'Purchased Credits',
        percent: p,
        tint: 'var(--credit)',
        left: amountLabel(q.extraUsage) || `${p}% used`,
        right: q.extraUsage.spendLimitReached ? 'Limit reached' : 'Monthly',
      }),
    );
  }

  const idle = !q.fiveHour?.resetsAt
    ? `<div class="notice" style="margin-top:14px">No session running — start a chat at
        <a href="https://claude.ai/new" target="_blank" rel="noreferrer noopener">claude.ai/new</a>.</div>`
    : '';

  return `<div class="rows">${rows.join('')}</div>${idle}`;
}

function commandCodeBody(card) {
  if (card.status === 'error') {
    return `<div class="notice error"><strong>Sync Failed</strong>${escape(card.error || 'Unauthorized')}</div>`;
  }
  if (!card.quota) return `<div class="notice">Syncing quotas…</div>`;

  const q = card.quota;
  const rows = [];

  if (q.hasCreditsInfo) {
    rows.push(
      quotaRow({
        title: 'Monthly Credits',
        percent: q.creditsUsedPct,
        tint: 'var(--commandcode)',
        left: `${money(q.totalPool - q.totalRemaining)} of ${money(q.totalPool)}`,
        right: `${money(q.totalRemaining)} left`,
        chip: q.planName ? `${q.planName}${q.planStatus && q.planStatus !== 'active' ? ` · ${q.planStatus}` : ''}` : null,
      }),
    );
  } else {
    rows.push(`<div class="notice">No credit usage this period yet.</div>`);
  }

  for (const [title, w, tint] of [
    ['Request Window (5h)', q.fiveHour, 'var(--accent)'],
    ['Weekly Requests', q.weekly, 'var(--info)'],
  ]) {
    if (!w) continue;
    rows.push(
      quotaRow({
        title,
        percent: w.usedPct,
        tint,
        left: `${Math.round(w.used)} of ${Math.round(w.cap)} requests`,
        right: w.exceeded ? 'Limit reached' : w.resetAt ? `Resets ${compactReset(w.resetAt)}` : 'Not started',
      }),
    );
  }

  const chips = [];
  if (q.totalSpent) chips.push(`<span class="chip">Spent <b>${money(q.totalSpent)}</b></span>`);
  if (q.requestCount) chips.push(`<span class="chip">Requests <b>${q.requestCount.toLocaleString()}</b></span>`);
  if (q.purchasedRemaining) chips.push(`<span class="chip">Purchased <b>${money(q.purchasedRemaining)}</b></span>`);
  if (q.periodEnd) chips.push(`<span class="chip">Renews <b>${timeUntil(q.periodEnd)}</b></span>`);
  if (!q.fiveHour && !q.weekly) chips.push(`<span class="chip">No request windows</span>`);

  return `<div class="rows">${rows.join('')}</div>${chips.length ? `<div class="chips">${chips.join('')}</div>` : ''}`;
}

function render() {
  const cards = [...state.values()];
  el('empty').hidden = cards.length > 0;

  grid.innerHTML = cards
    .map(
      (card) => `
      <article class="card" data-card="${escape(card.id)}">
        ${cardHead(card)}
        ${card.kind === 'claude' ? claudeBody(card) : commandCodeBody(card)}
      </article>`,
    )
    .join('');

  const states = cards.map((c) => c.status);
  const global =
    !cards.length ? 'idle'
    : states.includes('syncing') ? 'syncing'
    : states.every((s) => s === 'error') ? 'error'
    : states.includes('error') ? 'warning'
    : 'online';

  el('statusDot').dataset.state = global;
  el('statusLine').textContent =
    !cards.length ? 'No accounts linked'
    : global === 'syncing' ? 'Syncing…'
    : global === 'error' ? 'All accounts failed to sync'
    : global === 'warning' ? 'Some accounts failed to sync'
    : `${cards.length} ${cards.length === 1 ? 'provider' : 'providers'} tracked`;

  const newest = cards.map((c) => parseDate(c.fetchedAt)).filter(Boolean).sort((a, b) => b - a)[0];
  el('lastSync').textContent = newest ? `Last sync ${relative(newest.toISOString())}` : '';
}

// ── Data flow ──────────────────────────────────────────────────────────────

async function postJSON(path, body) {
  const res = await fetch(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(json.error || `Request failed (${res.status})`);
  return json;
}

/** Every card this deployment should show: host-configured, then browser-local. */
function cardDescriptors() {
  const descriptors = config.accounts.map((a) => ({
    id: `srv:${a.id}`,
    kind: 'claude',
    label: a.label,
    detail: a.masked,
    payload: { id: a.id },
    source: 'host',
  }));

  for (const account of localAccounts()) {
    descriptors.push({
      id: `loc:${account.id}`,
      kind: 'claude',
      label: account.label || 'Claude',
      detail: '',
      payload: { sessionKey: account.sessionKey, label: account.label },
      source: 'browser',
    });
  }

  const cmdKey = localCommandCodeKey();
  if (config.commandCode || cmdKey) {
    descriptors.push({
      id: 'cmd',
      kind: 'commandcode',
      label: 'Command Code',
      detail: '',
      payload: cmdKey ? { apiKey: cmdKey } : {},
      source: config.commandCode && !cmdKey ? 'host' : 'browser',
    });
  }

  return descriptors;
}

/** Prunes cards whose account no longer exists, so no stale reading lingers. */
function syncDescriptors() {
  const descriptors = cardDescriptors();
  const live = new Set(descriptors.map((d) => d.id));
  for (const id of [...state.keys()]) if (!live.has(id)) state.delete(id);

  for (const d of descriptors) {
    const existing = state.get(d.id);
    state.set(d.id, { ...(existing || { status: 'idle' }), ...d, ...(existing ? {} : {}) });
  }
  return descriptors;
}

async function refreshCard(id) {
  const card = state.get(id);
  if (!card) return;

  state.set(id, { ...card, status: 'syncing' });
  render();

  try {
    const path = card.kind === 'claude' ? '/api/claude' : '/api/commandcode';
    const result = await postJSON(path, card.payload);
    state.set(id, {
      ...state.get(id),
      status: result.status === 'error' ? 'error' : 'online',
      error: result.error || null,
      quota: result.quota || null,
      detail: result.email || result.label || result.masked || card.detail,
      fetchedAt: result.fetchedAt || new Date().toISOString(),
    });
  } catch (err) {
    state.set(id, { ...state.get(id), status: 'error', error: err.message });
  }
  render();
}

async function refreshAll() {
  const descriptors = syncDescriptors();
  render();
  await Promise.all(descriptors.map((d) => refreshCard(d.id)));
}

function scheduleRefresh() {
  if (timer) clearInterval(timer);
  const seconds = Number(el('interval').value);
  if (seconds > 0) timer = setInterval(refreshAll, seconds * 1000);
}

// ── Accounts sheet ─────────────────────────────────────────────────────────

function renderAccountList() {
  const items = [
    ...config.accounts.map(
      (a) => `<li><div class="who"><b>${escape(a.label)}</b><span>${escape(a.masked)}</span></div>
              <span class="src">host</span></li>`,
    ),
    ...localAccounts().map(
      (a) => `<li><div class="who"><b>${escape(a.label || 'Claude')}</b><span>${escape(maskLocal(a.sessionKey))}</span></div>
              <button class="icon-btn" type="button" data-remove="${escape(a.id)}" title="Remove" aria-label="Remove ${escape(a.label || 'account')}">✕</button></li>`,
    ),
  ];

  el('accountList').innerHTML =
    items.join('') || `<li><div class="who"><b>No accounts yet</b><span>Add a session key below</span></div></li>`;

  const cmdKey = localCommandCodeKey();
  el('cmdKey').value = cmdKey;
  el('cmdHint').textContent = config.commandCode
    ? 'A key is configured on the host; anything entered here overrides it in this browser.'
    : 'Optional. Leave blank if you do not use the Command Code CLI.';

  const addForm = el('addForm');
  addForm.hidden = !config.allowClientKeys;
  el('cmdForm').hidden = !config.allowClientKeys;
}

const maskLocal = (key) => (!key ? '' : key.length <= 12 ? '••••' : `${key.slice(0, 8)}…${key.slice(-4)}`);

function openSheet(open) {
  el('sheet').hidden = !open;
  if (open) renderAccountList();
}

// ── Wiring ─────────────────────────────────────────────────────────────────

el('refresh').addEventListener('click', refreshAll);
el('manage').addEventListener('click', () => openSheet(true));
el('sheetClose').addEventListener('click', () => openSheet(false));
el('sheet').addEventListener('click', (e) => { if (e.target === el('sheet')) openSheet(false); });
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') openSheet(false); });
document.addEventListener('click', (e) => {
  if (e.target.closest('[data-open-manage]')) openSheet(true);
  const sync = e.target.closest('[data-sync]');
  if (sync) refreshCard(sync.dataset.sync);
  const remove = e.target.closest('[data-remove]');
  if (remove) {
    writeStore(STORE.accounts, localAccounts().filter((a) => a.id !== remove.dataset.remove));
    renderAccountList();
    refreshAll();
  }
});

el('interval').addEventListener('change', () => {
  writeStore(STORE.interval, el('interval').value);
  scheduleRefresh();
});

el('addForm').addEventListener('submit', (e) => {
  e.preventDefault();
  const sessionKey = el('sessionKey').value.trim();
  if (!sessionKey) return;
  const label = el('label').value.trim() || `Account ${localAccounts().length + 1}`;
  writeStore(STORE.accounts, [
    ...localAccounts(),
    { id: `a${Date.now().toString(36)}`, label, sessionKey },
  ]);
  e.target.reset();
  renderAccountList();
  refreshAll();
});

el('cmdForm').addEventListener('submit', (e) => {
  e.preventDefault();
  const key = el('cmdKey').value.trim();
  writeStore(STORE.commandCode, key || null);
  renderAccountList();
  refreshAll();
});

el('cmdClear').addEventListener('click', () => {
  writeStore(STORE.commandCode, null);
  renderAccountList();
  refreshAll();
});

async function boot() {
  try {
    const res = await fetch('/api/config');
    if (res.ok) config = { ...config, ...(await res.json()) };
  } catch {
    /* static preview without functions — BYO-key mode still renders */
  }

  const saved = readStore(STORE.interval, null);
  const options = [...el('interval').options].map((o) => o.value);
  el('interval').value =
    saved && options.includes(String(saved)) ? String(saved)
    : options.includes(String(config.refreshSeconds)) ? String(config.refreshSeconds)
    : '300';

  scheduleRefresh();
  // Keep the "Updated …" / "Resets in …" labels honest between syncs.
  ticker = setInterval(render, 30000);
  await refreshAll();
  if (!state.size) openSheet(true);
}

boot();
