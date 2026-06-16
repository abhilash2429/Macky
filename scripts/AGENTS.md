# AGENTS.md - scripts

Scope: release and automation scripts only. Root instructions still apply.

## Purpose

This folder contains deployment automation. Treat it as production tooling, not as a convenient place for experimental helpers.

## Current Script

- `release.sh` builds, signs, packages, notarizes, signs Sparkle updates, generates `appcast.xml`, creates a GitHub Release, and pushes the appcast to the release repo.

## Safety Rules

- Do not run `release.sh` unless the user explicitly asks for a release run.
- Do not modify signing, notarization, Sparkle, GitHub release, or repo-push steps unless the task is specifically about release automation.
- Preserve `set -euo pipefail`.
- Keep paths and repo names explicit; avoid clever shell expansion for destructive operations.
- Do not add commands that delete outside the repo or a known build output directory.
- Be careful with existing branding in this script. It still references `makesomething`; changing that is a release/distribution decision, not a drive-by cleanup.

## Validation

- Prefer static validation by reading the command flow and checking quoted variables.
- For shell syntax on macOS/Linux, use `bash -n scripts/release.sh` when available.
- Do not perform live release, notarization, GitHub Release, or push steps as validation.
