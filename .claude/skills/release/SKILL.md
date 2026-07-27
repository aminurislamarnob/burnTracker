---
name: release
description: Ship a new BurnTracker version — bump the version, build the .dmg, cut the GitHub release, and update the landing page (feature copy + download links). Use when asked to "release", "cut a release", "ship vX.Y.Z", "update the branch", "publish the new version", or to point the landing page at a new build.
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

```bash
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
3. First launch: right-click the app → **Open** → **Open anyway** (the app is signed to run locally, so Gatekeeper shows a warning on a distributed build).

Requires macOS 13.0 (Ventura) or newer.
EOF
)" \
  build/BurnTracker-2.4.0.dmg
```

Conventions that every past release follows — keep them:

- Tag is `vX.Y.Z`, release title is `BurnTracker X.Y.Z` (tag has the `v`, title doesn't).
- The same one-line intro sentence opens every release.
- The **Install** section is verbatim boilerplate apart from the filename. The
  Gatekeeper step matters: the build is self-signed and not notarized.
- Attach exactly one asset, the `.dmg`.

Write the "What's new" bullets from the actual commits since the last tag
(`git log --oneline v2.3.1..HEAD`), phrased as user-visible benefits. Bold the
feature name, then explain. Skip pure refactors; mention a fix only if the user
would have noticed the bug.

## 4. Update the landing page

`landing/index.html` is the whole site (plus `styles.css`). Two separate jobs:

### 4a. Download links — always

Three `href`s and one version badge, all of which must move together:

```bash
sed -i '' 's|releases/download/v2\.3\.1/BurnTracker-2\.3\.1\.dmg|releases/download/v2.4.0/BurnTracker-2.4.0.dmg|g; \
           s|<span class="btn-ver">v2\.3\.1</span>|<span class="btn-ver">v2.4.0</span>|g' \
  landing/index.html

grep -n "2\.4\.0" landing/index.html    # expect 4 hits: nav, hero, download CTA href, btn-ver
```

The three links are the nav bar button, the hero CTA, and the download-section CTA.
If you get fewer than four hits, a link was missed.

### 4b. Feature copy — when the release adds a user-visible feature

This is the step that gets forgotten. The download link is mechanical; the feature
grid is the part that actually sells the release, and it has silently fallen behind
before (menu-bar pinning shipped in 2.3.0 and only reached the page in 2.3.1).

Before writing, check what the page already claims: read the `.feature-grid`
section and the `.strip` items, and compare against the last few releases' notes.
Anything shipped-but-unmentioned is fair game to fold in now.

Add a card in the existing shape:

```html
<article class="feature-card">
  <span class="feature-icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><!-- 24x24 stroke icon --></svg></span>
  <h3>Sentence-case title</h3>
  <p>One or two sentences, benefit-first, matching the voice of the neighbouring cards.</p>
</article>
```

Constraints:

- **`.feature-grid` is `repeat(3, 1fr)`** (`landing/styles.css`), collapsing to 2
  columns under 900px and 1 under 600px. Keep the card count a multiple of three or
  the last row is visibly ragged. If a release adds two features and that would
  leave an orphan, combine them into one well-written card rather than shipping a
  lopsided grid.
- Icons are inline 24×24 stroke SVGs, `stroke-width="1.8"`, no fills. Match the set.
- Copy is benefit-first and free of implementation detail — the release notes are
  where mechanics go, not the landing page.
- The `.strip` band near the top holds four short trust claims. Update it only when
  a release changes what the app fundamentally *is* (e.g. a new provider), not for
  every feature.

### 4c. Ship it

```bash
git add landing/index.html
git commit -m "docs: Point landing page at v2.4.0 …"
git push origin develop
```

`.github/workflows/deploy-pages.yml` deploys to GitHub Pages on push to `develop`,
but **only when the diff touches `landing/**`**. A landing change bundled into a
commit that the workflow's path filter still matches is fine; just don't expect a
deploy from a push that never touched `landing/`.

## 5. Verify

```bash
gh run list --limit 1                                    # Pages deploy succeeded
gh release view v2.4.0 --json assets --jq '.assets[].name'   # the .dmg is attached
curl -sIL -o /dev/null -w '%{http_code}\n' \
  https://github.com/aminurislamarnob/burnTracker/releases/download/v2.4.0/BurnTracker-2.4.0.dmg
```

The download should end at `200`. If it's a 404, the release exists but the asset
upload failed — re-upload with `gh release upload v2.4.0 build/BurnTracker-2.4.0.dmg`.

## Commit message conventions

Follow the existing log: a `type: Subject` first line in the imperative, sentence
case, no trailing period. Types in use: `feat`, `fix`, `docs`, `chore`. Bodies
explain *why*, wrapped at ~72 columns. Every commit ends with:

```
Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
```

A pure version bump with no feature attached is `chore: Bump version to X.Y.Z`.

## Notes

- There is no test suite and no linter. "Verified" means the Release build succeeds
  and, for UI work, that the app was launched and the change exercised by hand.
- The app is a menu-bar accessory with no Dock icon. To smoke-test a build:
  `pkill -f BurnTracker.app` then `open build/Build/Products/Release/BurnTracker.app`,
  and click the menu-bar icon.
- Never commit `build/`, and never put a session key or API token in release notes,
  the landing page, or a commit message.
