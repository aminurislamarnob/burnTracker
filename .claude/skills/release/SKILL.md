---
name: release
description: Ship a new BurnTracker version — bump the version, build the .dmg, cut the GitHub release, and update the landing page (feature copy + download links) in the separate aminurislam.me repo. Use when asked to "release", "cut a release", "ship vX.Y.Z", "update the branch", "publish the new version", or to point the landing page at a new build.
---

# Releasing BurnTracker

A release is four things that must happen **in this order**, because each depends on
the one before it:

1. Bump the version in the Xcode project.
2. Build the `.dmg` (its filename is read from the built app, so the bump must land first).
3. Create the GitHub release and attach the `.dmg`.
4. Point the landing page at the new download **and** describe what's new.

Step 4 must come after step 3 or the live site's Download buttons 404 until the
release exists. Never push a landing-page version bump for a release you have not
created yet.

**The landing page is not in this repo.** It lives at
<https://aminurislam.me/burn-tracker> in the portfolio repo
**`aminurislamarnob/aminurislam.me`**. Step 4 is a separate clone, branch, commit
and deploy; steps 0–3 never touch it. (This repo had a `landing/` directory and a
GitHub Pages workflow until the page moved — if you find references to either,
they are stale.)

## 0. Preflight

```bash
git rev-parse --abbrev-ref HEAD      # expect: develop
git status --short                   # expect: clean, or only the work being released
gh release list --limit 3            # what shipped last, and what tag to beat
```

`develop` is the default branch and the release target — there is no `main`.

Decide the version with semver against what actually changed: a new provider or a
user-visible capability is a minor bump, a fix or a polish pass is a patch. Confirm
the number with the user if they did not name one.

## 1. Bump the version

Both live in `BurnTracker.xcodeproj/project.pbxproj`, and **each appears twice** —
once in the Debug config and once in Release. All four values must change:

```bash
sed -i '' 's/MARKETING_VERSION = 2\.3\.1;/MARKETING_VERSION = 2.4.0;/g; \
           s/CURRENT_PROJECT_VERSION = 5;/CURRENT_PROJECT_VERSION = 6;/g' \
  BurnTracker.xcodeproj/project.pbxproj

grep -n "MARKETING_VERSION\|CURRENT_PROJECT_VERSION" BurnTracker.xcodeproj/project.pbxproj
```

Expect exactly four lines back. `MARKETING_VERSION` is the user-facing `2.4.0`;
`CURRENT_PROJECT_VERSION` is an opaque build counter that just increments by one.

Verify it still builds, then commit and push. Feature work and its version bump can
share one commit — see the message conventions at the bottom.

```bash
xcodebuild -project BurnTracker.xcodeproj -scheme BurnTracker \
  -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD"
git push origin develop
```

Push before creating the release: the tag is cut from `develop`, so the commit has
to be on the remote first.

## 2. Build the .dmg

```bash
./scripts/make-dmg.sh          # clean Release build + hdiutil; takes a few minutes
```

Run it in the background and carry on with the landing-page copy while it works.

It reads `CFBundleShortVersionString` from the built app, so the output filename
proves the bump landed:

```
build/BurnTracker-<version>.dmg
```

If that filename shows the *old* version, step 1 did not take — fix it and rebuild
rather than renaming the file. `build/` is gitignored; the `.dmg` is never committed.

## 3. Create the GitHub release

````bash
gh release create v2.4.0 \
  --target develop \
  --title "BurnTracker 2.4.0" \
  --notes "$(cat <<'EOF'
Native SwiftUI menu-bar app for tracking Claude.ai, Antigravity, Gemini CLI, and Command Code usage.

## What's new in 2.4.0

- **Headline feature** — what it does for the user, in their terms, not the implementation's. Say why they'd want it.
- **Second feature** — same.

## Install

1. Download `BurnTracker-2.4.0.dmg` below.
2. Open it and drag **BurnTracker** to **Applications**.
3. First launch: macOS blocks the app — it is signed to run locally rather than notarized, so Gatekeeper quarantines the download. Clear the flag once:

   ```
   xattr -dr com.apple.quarantine /Applications/BurnTracker.app
   ```

   Then open it normally. Prefer not to use the terminal? After the blocked launch, go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.

Requires macOS 15.0 (Sequoia) or newer.
EOF
)" \
  build/BurnTracker-2.4.0.dmg
````

Conventions that every past release follows — keep them:

- Tag is `vX.Y.Z`, release title is `BurnTracker X.Y.Z` (tag has the `v`, title doesn't).
- The same one-line intro sentence opens every release.
- The **Install** section is verbatim boilerplate apart from the filename. The
  Gatekeeper step matters: the build is self-signed and not notarized. Do **not**
  reword it back to “right-click → Open → Open anyway” — that bypass is gone on
  macOS 15+, where the dialog offers only *Move to Trash* / *Done*, so the
  `xattr -dr com.apple.quarantine` line is the only advice that works on every
  supported version. Keep it in step with the README's Download section.
- Attach exactly one asset, the `.dmg`.

Write the "What's new" bullets from the actual commits since the last tag
(`git log --oneline v2.3.1..HEAD`), phrased as user-visible benefits. Bold the
feature name, then explain. Skip pure refactors; mention a fix only if the user
would have noticed the bug.

## 4. Update the landing page (separate repo)

| | |
|---|---|
| Repo | `aminurislamarnob/aminurislam.me` |
| Local clone | `~/Herd/aiarnob-nuxt-app` — **the folder name is the repo's old name**, don't go looking for `aminurislam.me/` |
| Branch | `production` (there is no `main`) |
| Page | `app/components/Products/BurnTracker.vue` — one component holds the whole page |
| URL | <https://aminurislam.me/burn-tracker> |

It is a Nuxt 4 static site, not the hand-written HTML this repo used to carry.
Node 22 (`nvm use`), `npm`, and `npx nuxi generate` to build.

```bash
cd ~/Herd/aiarnob-nuxt-app
git checkout production && git pull --ff-only
```

### 4a. Download links — always

Four constants at the top of the `<script setup>` block. `version` and `dmgUrl`
**must move together** — the `.dmg` is a versioned release asset, so a bumped
version against a stale URL 404s:

```bash
sed -i '' 's/const version = "2\.3\.1"/const version = "2.4.0"/; \
           s|releases/download/v2\.3\.1/BurnTracker-2\.3\.1\.dmg|releases/download/v2.4.0/BurnTracker-2.4.0.dmg|' \
  app/components/Products/BurnTracker.vue

grep -n "2\.4\.0" app/components/Products/BurnTracker.vue   # expect 2 hits: version, dmgUrl
```

`requires` (the minimum macOS) only changes when the deployment target does.
The version renders in the Download CTA as `v{{ version }}`; there is no separate
badge string to keep in sync, unlike the old page.

### 4b. Feature copy — when the release adds a user-visible feature

This is the step that gets forgotten. The download link is mechanical; the feature
grid is the part that actually sells the release, and it has silently fallen behind
before (menu-bar pinning shipped in 2.3.0 and only reached the page in 2.3.1).

The grid is driven by the `features` array in the same `<script setup>` — add an
entry rather than writing markup:

```js
{
  icon: resolveComponent("LucideGauge"),
  title: "Sentence-case title",
  body: "One or two sentences, benefit-first, matching the voice of the neighbouring entries.",
},
```

Constraints:

- **Keep the count a multiple of three.** `.pz-grid--3` is three columns on desktop
  (two at ≥640px, one below); there are 9 entries today. If a release adds two
  features and that would leave an orphan, combine them into one well-written entry
  rather than shipping a ragged last row.
- **Icons go through `resolveComponent("LucideX")`, never a direct import.**
  `@lucide/vue` is a transitive dependency of `nuxt-lucide-icons`, not a direct one,
  and resolving by name is what lets the entry live in an array. Verify the glyph
  exists before using it — v1 dropped the brand icons, so there is no
  `LucideGithub` (the repo links use `LucideGitFork`):

  ```bash
  node -e 'const d=require("fs").readFileSync("node_modules/@lucide/vue/dist/lucide-vue.prefixed.d.ts","utf8");
           console.log(/LucideGauge\b/.test(d) ? "ok" : "MISSING")'
  ```

- Copy is benefit-first and free of implementation detail — the release notes are
  where mechanics go, not the landing page.
- The four-cell `highlights` band under the hero holds short trust claims. Update it
  only when a release changes what the app fundamentally *is* (e.g. a new provider),
  not for every feature.

### 4c. Screenshots — only if the UI changed

`public/images/burntracker-popover.png` is the app's popover, cropped to its own
bounds with transparent corners (no desktop wallpaper around it). If you replace it,
**give it a new filename and update the `src`** — assets are served
`immutable, s-maxage=86400`, so Cloudflare will keep serving the old bytes from its
edge for a day if you overwrite in place.

### 4d. Ship it

The deploy is **tag-triggered, not branch-triggered** — this is the single biggest
difference from the old workflow. Pushing to `production` deploys nothing:

```bash
npx nuxi generate                    # must exit 0 and prerender /burn-tracker
git add app/components/Products/BurnTracker.vue
git commit -m "Point the burn-tracker page at v2.4.0"
git push origin production

git tag -a v2.2.17 -m "Point the burn-tracker page at v2.4.0"   # site's own series
git push origin v2.2.17
```

`.github/workflows/deployTocPanel.yml` fires on `push: tags`, runs `npx nuxi
generate` and FTPs `.output/public/` to cPanel.

Two traps:

- **The site's tags are its own series, unrelated to BurnTracker's.** The site is on
  `v2.2.x`; the app is on `v2.x`. Check `git tag --sort=-v:refname | head -1` and
  increment *that*. Never tag the site with the app's version.
- **`/burn-tracker` is listed explicitly in `nitro.prerender.routes`** because
  nothing on the site links to it, so `crawlLinks` cannot reach it. If that entry is
  removed the page silently vanishes from the static build and 404s in production.

## 5. Verify

```bash
gh release view v2.4.0 --json assets --jq '.assets[].name'   # the .dmg is attached
curl -sIL -o /dev/null -w '%{http_code}\n' \
  https://github.com/aminurislamarnob/burnTracker/releases/download/v2.4.0/BurnTracker-2.4.0.dmg

# landing page — in the portfolio repo, not this one
gh run list --repo aminurislamarnob/aminurislam.me --limit 1     # FTP deploy succeeded
curl -s https://aminurislam.me/burn-tracker/ | grep -o 'BurnTracker-2\.4\.0\.dmg' | head -1
```

The download should end at `200`. If it's a 404, the release exists but the asset
upload failed — re-upload with `gh release upload v2.4.0 build/BurnTracker-2.4.0.dmg`.

The live page can lag a minute or two behind the deploy, and Cloudflare caches the
HTML briefly; re-check before assuming the tag did not take.

## Commit message conventions

Follow the existing log: a `type: Subject` first line in the imperative, sentence
case, no trailing period. Types in use: `feat`, `fix`, `docs`, `chore`. Bodies
explain *why*, wrapped at ~72 columns. Every commit ends with:

```
Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
```

A pure version bump with no feature attached is `chore: Bump version to X.Y.Z`.

**This applies to this repo only.** The portfolio repo does not use the `type:`
prefix — its log is plain imperative subjects ("Rename the popover image to bust its
CDN cache"). Match whichever repo you are committing in.

## Notes

- There is no test suite and no linter. "Verified" means the Release build succeeds
  and, for UI work, that the app was launched and the change exercised by hand.
- The app is a menu-bar accessory with no Dock icon. To smoke-test a build:
  `pkill -f BurnTracker.app` then `open build/Build/Products/Release/BurnTracker.app`,
  and click the menu-bar icon.
- Never commit `build/`, and never put a session key or API token in release notes,
  the landing page, or a commit message.
