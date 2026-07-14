# AGENTS.md — leanring-buddy.xcodeproj (Xcode project metadata)

README and operating manual for the Xcode project configuration. Root `AGENTS.md` still
applies. A **User Instructions** section for humans is at the end.

---

## 1. Purpose

This folder defines the app target, build settings, Swift Package products, resources,
entitlements wiring, and source-file membership for the Macky macOS app. Everything that
tells Xcode *how* to build `leanring-buddy/` lives here.

---

## 2. Layout

- `project.pbxproj` — the project graph: targets, build phases, build settings, file
  references, and SPM product links. The authoritative file; most edits here are made by
  Xcode, not by hand.
- `project.xcworkspace/` — workspace wrapper, including `xcshareddata/swiftpm/` which pins
  resolved Swift Package versions (`Package.resolved`).
- `xcuserdata/` — per-user Xcode state (breakpoints, schemes, window layout). Personal and
  noisy in diffs; avoid touching unless intentionally changing a shared scheme.

---

## 3. Current Project Facts

- **Main app target:** `leanring-buddy` (builds a product named `Macky.app`).
- **Bundle identifier:** `com.speedmac.Macky` (Macky branding).
- **Minimum macOS target:** 14.2.
- **Swift version:** 5.0 in project settings.
- **Swift Package pins:** Sparkle (auto-update) and PostHog (analytics).
- **Test targets** may be absent or deleted in the current working tree — verify before
  relying on them.

---

## 4. Rules

- Do **not** rename the project, scheme, target, or the legacy `leanring-buddy` paths
  unless explicitly asked. The folder/scheme/project names are intentional legacy.
- Edit `project.pbxproj` only when necessary: adding/removing source files, resources,
  build settings, package products, or entitlements references.
- When adding Swift files under `leanring-buddy/`, verify they are members of the
  `leanring-buddy` app target — a file not in the target silently won't compile into the
  app.
- Keep package changes intentional. Adding or updating a Swift Package is a dependency
  decision; call it out.
- Preserve signing and bundle settings unless the task is specifically about distribution
  or identity.

---

## 5. Validation

- After any `project.pbxproj` edit, inspect the changed hunk manually — these diffs are
  easy to corrupt.
- On macOS, prefer opening the project in Xcode and building there.
- When you cannot open/build the project, say so explicitly and rely on static review of
  the `project.pbxproj` diff.

---

## User Instructions

For a human working with the project.

- **Open:** double-click `leanring-buddy.xcodeproj` (or `open leanring-buddy.xcodeproj`
  from the repo root) to launch it in Xcode.
- **First build:** run a build once so Swift Package Manager downloads Sparkle and PostHog.
  The Sparkle CLI tools fetched here are also what the release script
  depends on.
- **Add a source file:** add it to the `leanring-buddy` group in Xcode and confirm the
  `leanring-buddy` target checkbox is ticked under *Target Membership*.
- **Update dependencies:** use *File ▸ Packages ▸ Update to Latest Package Versions* in
  Xcode; commit the resulting `Package.resolved` change deliberately.
- **Reset package state** if SPM gets stuck: *File ▸ Packages ▸ Reset Package Caches*, then
  rebuild.
