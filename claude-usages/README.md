# Claude Usage — web dashboard

A standalone, hostable dashboard that shows the same live quotas as the
BurnTracker menu-bar app: Claude.ai 5-hour sessions, weekly limits, per-model
weekly caps, purchased credits, and Command Code credits/request windows.

It is **fully self-contained**: nothing in this folder is compiled into
`BurnTracker.app`, and no app source was changed to add it. The macOS project
uses a file-system-synchronized group scoped to `BurnTracker/`, so a sibling
folder like this one is never a target member.

```
claude-usages/
  api/
    config.js          GET  — host-configured accounts (labels only) + settings
    claude.js          POST — one Claude account's live quota
    commandcode.js     POST — Command Code credits + request windows
    _lib/              shared libs (underscored, so Vercel treats them as code)
      claude.js        port of ClaudeService + QuotaData decoding
      commandcode.js   port of CommandCodeService (plan table + credit projection)
      http.js          JSON/body/env helpers
  public/              the dashboard (no build step, no dependencies)
    index.html  styles.css  app.js
  dev-server.mjs       dependency-free local server with the same routes
  vercel.json  package.json  .env.example
```

## Why the API functions exist

The dashboard cannot call `claude.ai/api/*` from the browser:

- `Cookie` is a [forbidden header name](https://developer.mozilla.org/en-US/docs/Glossary/Forbidden_header_name) — JS cannot set `sessionKey=…` on a request.
- The session cookie is `HttpOnly`, so page scripts can't read it either.
- The private API sends no CORS headers, so a cross-origin read is blocked regardless.

So each `/api/*` function does what the Swift service does: sends the cookie
header verbatim, resolves the first organization, then reads
`/organizations/{orgId}/usage`. The dual snake_case/camelCase decoding is ported
as-is, because the upstream field naming is not guaranteed.

## Run locally

```bash
cd claude-usages
npm run dev           # → http://localhost:3000   (no install needed, Node 20+)
```

Then click **Accounts** and paste a session key, or start it with host-configured
keys:

```bash
CLAUDE_SESSION_KEYS='[{"label":"Personal","sessionKey":"sk-ant-sid01-…"}]' npm run dev
```

`npm run dev:vercel` uses `vercel dev` instead, if you want the real runtime.

## Deploy

```bash
npm i -g vercel
cd claude-usages
vercel            # first deploy: accept the defaults, root = this folder
vercel --prod
```

Zero-config: `public/` is served statically and every `api/*.js` becomes a Node
function. It deploys the same way on Netlify (`netlify/functions`), Cloudflare
Pages Functions, or any Node host — only the function wrapper differs.

### Environment variables (all optional)

| Variable | Effect |
| --- | --- |
| `CLAUDE_SESSION_KEYS` | Accounts the host owns. JSON array of `{label, sessionKey}`, or a compact `Label=key,Label2=key2` list. Keys never reach the browser — it only receives labels and a masked hint. |
| `COMMAND_CODE_API_KEY` | The `apiKey` value from `~/.commandcode/auth.json`. |
| `REFRESH_SECONDS` | Default auto-refresh interval (min 30, default 300). |
| `ALLOW_CLIENT_KEYS` | Set to `false` to hide the key inputs and serve only host-configured accounts. |

## Two ways to hold keys

**Host-configured** (`CLAUDE_SESSION_KEYS`) — the key stays in the deployment's
environment; the browser sends only an account id. Best for a private deploy.

**Bring-your-own-key** — the key lives in this browser's `localStorage` and is
sent to *this deployment's* `/api/claude` over HTTPS on each fetch. It is never
persisted server-side. Best for a shared/public URL where each visitor watches
their own account.

Either way the key is transmitted to exactly two places: this deployment and
claude.ai. Responses are `no-store`, and the page is `noindex`.

> **Host it privately.** Anyone who can open a deployment with
> `CLAUDE_SESSION_KEYS` set can read that account's usage. Vercel's
> Password Protection / Vercel Authentication (Project → Settings → Deployment
> Protection) is the simplest fix.

## What this dashboard does not do

- **Antigravity is not included.** Its quota comes from a language server on
  `127.0.0.1` behind a self-signed cert, with a CSRF token discovered by reading
  process argv (`ps`) and per-pid sockets (`lsof`). A hosted page can neither
  reach that loopback address nor trust that certificate — it only works from a
  process on the same machine, which is what the macOS app is for.
- No menu-bar pin, no native notifications, no session-launch webview — those
  are app features. Alert thresholds live in the app.
- It does not read `~/.claude/tracker-settings.json`. Accounts are configured
  per deployment (env) or per browser (localStorage), so the two stay decoupled.

## Keeping the ports in step

Two files mirror app logic and should be updated together with their Swift
counterparts:

- `api/_lib/claude.js` ↔ `BurnTracker/Services/ClaudeService.swift`,
  `BurnTracker/Models/QuotaData.swift` — including the rule that model-scoped
  weekly caps come only from the `limits` array (`kind: weekly_scoped`,
  `group: weekly`, `scope.model.display_name`), matched by display name rather
  than a hard-coded model, and omitted entirely on plans without one.
- `api/_lib/commandcode.js` ↔ `BurnTracker/Services/CommandCodeService.swift` —
  the per-plan allowance table and the `max(planAllowance, monthlyRemaining)`
  pool term that makes the percentage match `cmd`'s own `/usage` view.
