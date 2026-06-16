# AGENTS.md - leanring-buddy.xcodeproj

Scope: Xcode project metadata only. Root instructions still apply.

## Purpose

This folder defines app targets, build settings, package products, resources, entitlements wiring, and file membership for the active macOS app.

## Current Project Facts

- Main app target: `leanring-buddy`
- Test targets may be absent or deleted in the current working tree. Verify before relying on them.
- Bundle identifier currently uses Speed branding: `com.speedmac.Speed`.
- Minimum macOS target is 14.2.
- Swift version is 5.0 in project settings.
- Swift Package pins include Sparkle, PostHog, and PLCrashReporter.

## Rules

- Do not rename the project, scheme, target, or legacy `leanring-buddy` paths unless explicitly asked.
- Edit `project.pbxproj` only when necessary, such as adding/removing source files, resources, build settings, package products, or entitlements references.
- When adding Swift files under `leanring-buddy/`, verify they are part of the app target.
- Keep package changes intentional. Adding or updating Swift Packages is a dependency decision and should be called out.
- Preserve signing and bundle settings unless the task is specifically about distribution or identity.

## Validation

- After project metadata edits, inspect the changed `project.pbxproj` hunk manually.
- On macOS, prefer opening the project in Xcode and building there.
- In this Windows workspace, report that Xcode validation was not run if you cannot open/build the project.
