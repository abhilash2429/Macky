# AGENTS.md - worker

Scope: Cloudflare Worker only. Root instructions still apply.

## Purpose

The Worker is the network boundary between the macOS app and external services. It keeps secrets out of the app bundle and exposes routes used by `RealtimeClient` and `AuthManager`.

## Current Routes

- `GET /realtime` - WebSocket upgrade. Proxies bytes between the Swift client and Azure AI Foundry realtime endpoint using `AZURE_OPENAI_API_KEY`.
- `GET /composio-config` - Creates a Composio Tool Router session for the current fixed test user and returns `{ url, key }` for the Swift realtime session's MCP tool entry.
- `POST /auth/magic-link` - Stores a one-time token in KV and returns a `Speed://auth?token=...` link for manual/local testing. It does not send email yet.
- `POST /auth/verify` - Consumes a magic-link token, best-effort provisions the Composio user, and returns an opaque session token plus `composioUserId`.

## Files

- `src/index.ts` - All Worker route handlers and proxy logic.
- `wrangler.toml` - Worker name, entrypoint, compatibility date, and KV namespace binding.
- `.wrangler/` - Local Wrangler state/cache. Do not commit secrets from local state.

## Required Bindings And Secrets

- `AZURE_OPENAI_API_KEY` - Secret used by `/realtime`.
- `COMPOSIO_API_KEY` - Secret used by `/composio-config` and Composio provisioning.
- `AUTH_TOKENS` - Cloudflare KV namespace for pending magic-link tokens.

Use Wrangler secret commands for secrets. Never hardcode them in source or docs.

## Invariants

- Keep `/realtime` as a byte-forwarding WebSocket proxy. Do not parse, transform, log full payloads, or add compute-heavy message handling in the proxy path.
- Validate request method and input shape for JSON routes.
- Magic-link tokens are single-use and expire through KV `expirationTtl`.
- The current Composio user is fixed as `speed-test-user`; changing this is an auth/product decision.
- Worker state is not durable except KV. Do not rely on module-level mutable state for sessions.

## Ask Before

- Adding or renaming a route.
- Changing the Azure realtime URL, model query parameter, or auth header.
- Changing the Composio session payload, fixed user behavior, or returned config shape.
- Adding npm dependencies or a package manifest.
- Replacing KV token storage with another persistence mechanism.

## Validation

- Static check first: read `src/index.ts`, then `rg -n` for route names in the Swift app.
- Local run, when secrets are available: `npx wrangler dev`.
- Deploy only when explicitly requested: `npx wrangler deploy`.
- If testing auth locally, remember `/auth/magic-link` returns the deep link in the response instead of sending email.
