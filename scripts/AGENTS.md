# AGENTS.md — scripts (release automation)

README and operating manual for release/automation scripts. Root `AGENTS.md` still
applies. A **User Instructions** section for humans is at the end. (See also
`scripts/README.md` for the human-facing quick start.)

> Scope: release and deployment tooling only. This is **production tooling**, not a
> convenient place for experimental helpers.

---

## 1. Contents

- `release.sh` — the full release pipeline (build → sign → DMG → notarize → Sparkle
  appcast → GitHub Release → push appcast).
- `README.md` — human quick-start and one-time prerequisites for `release.sh`.

---

## 2. What `release.sh` Does

Runs `set -euo pipefail` and, in order:

1. Auto-detects the version + build from the latest GitHub Release (or takes them as
   args), then confirms with a prompt before running anything.
2. Archives the app via `xcodebuild` (scheme `leanring-buddy`).
3. Exports a signed `.app` with the Developer ID certificate.
4. Wraps it in a DMG with the drag-to-Applications background.
5. Notarizes the DMG with Apple so Gatekeeper won't block it.
6. Signs the DMG with the Sparkle EdDSA key (from Keychain).
7. Generates/updates `appcast.xml` for Sparkle auto-updates.
8. Creates a GitHub Release with the DMG attached.
9. Pushes the updated `appcast.xml` to the releases repo.

### Key configuration (top of `release.sh`)
- `SCHEME="leanring-buddy"` — the Xcode scheme that builds the app.
- `APP_NAME="makesomething"` — legacy product/artifact name still used for archive and
  DMG paths.
- `GITHUB_REPO="julianjear/makesomething-mac-app"` — the releases repo the appcast is
  pushed to.
- Sparkle CLI tools are auto-discovered from Xcode's SPM DerivedData cache; the script
  errors out early if they aren't present (build in Xcode once first).

### Usage shapes
```bash
./scripts/release.sh            # auto-bump: 1.5 → 1.6, build 6 → 7
./scripts/release.sh 2.0        # set marketing version, auto-bump build
./scripts/release.sh 2.0 10     # set both marketing version and build number
```

---

## 3. Safety Rules (for agents)

- **Do not run `release.sh`** unless the user explicitly asks for a release run. It signs,
  notarizes, publishes a GitHub Release, and pushes to another repo — all hard to undo.
- Do not modify signing, notarization, Sparkle, GitHub-release, or repo-push steps unless
  the task is specifically about release automation.
- Preserve `set -euo pipefail`.
- Keep paths and repo names explicit; avoid clever shell expansion for destructive
  operations.
- Do not add commands that delete outside the repo or a known build-output directory.
- The script still references legacy `makesomething` branding (and the
  `julianjear/makesomething-mac-app` repo). Changing that is a deliberate
  release/distribution decision, **not** a drive-by cleanup.

---

## 4. Validation

- Prefer static validation: read the command flow and check that variables are quoted.
- Check shell syntax without executing: `bash -n scripts/release.sh`.
- **Never** perform a live release, notarization, GitHub Release, or push as a form of
  validation.

---

## User Instructions

For a human shipping a release. Full details are in `scripts/README.md`.

### One-time prerequisites
1. Xcode with your **Developer ID** signing certificate installed.
2. Homebrew tools: `brew install create-dmg gh`.
3. GitHub CLI authenticated: `gh auth login`.
4. Apple notarization credentials in Keychain:
   ```bash
   xcrun notarytool store-credentials "AC_PASSWORD" \
       --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
   ```
   (Use an app-specific password from appleid.apple.com.)
5. Sparkle EdDSA key in Keychain (generated during initial Sparkle setup).
6. Build the project in Xcode at least once so SPM downloads Sparkle and its CLI tools.

### Ship it
```bash
./scripts/release.sh          # or pass an explicit version / build
```
The script shows the computed version, build, and previous release, then waits for a `y`
confirmation. If the tag already exists on GitHub it exits early and tells you what to do.
