# AGENTS.md — worker (Cloudflare Worker proxy)

README and operating manual for the Cloudflare Worker. Root `AGENTS.md` still applies. A
**User Instructions** section for humans is at the end.

---

## 1. Purpose

The Worker (`realtime-proxy`) is the **network boundary** between the macOS app and
external services. It keeps every secret out of the app bundle and exposes the routes
used by `RealtimeClient` and `AuthManager`. The app never talks to Azure/OpenAI or
Composio directly — it always goes through here.

Crucially, `/realtime` is a **byte-forwarding WebSocket proxy**: the app connects to the
Worker, the Worker proxies the socket to the realtime endpoint, and bytes flow through
without per-message compute. This is deliberate — a persistent socket doing real work
would hit Cloudflare's CPU-time limit; pure proxying does not.

---

## 2. Routes (`src/index.ts`)

| Method & path | What it does |
|---------------|--------------|
| `GET /realtime` | WebSocket upgrade. Proxies bytes between the Swift client and the Azure AI Foundry realtime endpoint (`…/openai/v1/realtime?model=gpt-realtime-2`) using `AZURE_OPENAI_API_KEY`. Both sockets are wired together and torn down as a pair. |
| `GET /composio-config` | Creates a Composio Tool Router session for the fixed `COMPOSIO_USER_ID` and returns `{ url, key }`, which the Swift client wires into the realtime `session.update` as an `mcp` tool entry. No `toolkits` allowlist is sent (full catalog via search); `manage_connections` is enabled with `enable_wait_for_connections: false` so a voice turn never blocks on OAuth. |
| `POST /spotify-play` | Fast, direct "play a track by name" path. Body `{ query, uri? }`. Does SPOTIFY_SEARCH_FOR_ITEM → SPOTIFY_START_RESUME_PLAYBACK server-side in one hop (via the Composio REST *execute* endpoint, not the MCP tool-router), targeting an active device when one exists and falling back to SPOTIFY_TRANSFER_PLAYBACK for an idle one. Returns `{ status:"playing", track, artist }`, or `{ needs_device:true, uri, … }` when Spotify has no awake device (the app opens Spotify locally and retries with the `uri`). Bypasses the slow model-driven MCP discovery chain that caused named-song playback to stall or silently no-op. Called by the `play_spotify_track` native tool. |
| `POST /auth/magic-link` | Validates `{ email }`, stores a one-time token (`token → email`) in `AUTH_TOKENS` KV with a 15-minute TTL, and emails a clickable link via Resend. The link points at the https `/auth/open` endpoint (custom schemes aren't clickable in webmail). |
| `POST /auth/verify` | Consumes a magic-link token (single-use; deleted on first success), best-effort provisions the Composio user for that email, and returns `{ sessionJWT, composioUserId }`. |
| `GET /auth/open?token=…` | Minimal HTML bridge that bounces the browser into the app via `Macky://auth?token=…`. Validates the token shape (UUID-ish) before reflecting it into the deep link. |

---

## 3. Files

- `src/index.ts` — all route handlers and proxy logic.
- `wrangler.toml` — Worker name (`realtime-proxy`), entrypoint, compatibility date, the
  `AUTH_TOKENS` KV namespace binding, and the `MAGIC_LINK_FROM` / `PUBLIC_BASE_URL` vars.
- `.wrangler/` — local Wrangler state/cache. Do not commit secrets from local state.
- `worker_agents.md` — **deprecated** pointer file; this `AGENTS.md` is the current guide.

---

## 4. Bindings, Secrets & Vars

**Secrets** (set with `npx wrangler secret put <NAME>`, never in source or `wrangler.toml`):

- `AZURE_OPENAI_API_KEY` — used by `/realtime` to authenticate to the Azure realtime endpoint.
- `COMPOSIO_API_KEY` — used by `/composio-config` and Composio user provisioning.
- `RESEND_API_KEY` — used to deliver magic-link emails via the Resend HTTP API.

**KV namespace:**

- `AUTH_TOKENS` — pending magic-link tokens (`token → email`), TTL'd via `expirationTtl`.

**Plain vars (in `wrangler.toml`):**

- `MAGIC_LINK_FROM` — sender address. Default `onboarding@resend.dev` works with no domain
  but only delivers to the address the Resend account signed up with; switch to an address
  on a verified Resend domain to email anyone.
- `PUBLIC_BASE_URL` — public origin of the Worker, used to build the clickable email link
  (`https://realtime-proxy.speedmac.workers.dev`).

---

## 5. Invariants (do not break)

- Keep `/realtime` a pure byte-forwarding WebSocket proxy. Do not parse, transform, log
  full payloads, or add compute-heavy handling in the proxy path.
- Validate request method and input shape for JSON routes; reflect only validated values.
- Magic-link tokens are **single-use** and expire via KV `expirationTtl` (15 min).
- The current Composio user is fixed as `speed-test-user` (`COMPOSIO_USER_ID`). Per-user
  auth is a future milestone that swaps this one line — changing it now is an auth/product
  decision.
- Worker state is not durable except KV. Do not rely on module-level mutable state for
  sessions.
- Composio user provisioning in `/auth/verify` is best-effort: a Composio hiccup must not
  block login.

---

## 6. Ask Before

- Adding or renaming a route.
- Changing the Azure realtime URL, the `model` query parameter, or the auth header.
- Changing the Composio session payload, fixed-user behavior, or returned config shape.
- Changing the magic-link email content, sender logic, or the `/auth/open` redirect bridge.
- Adding npm dependencies or a package manifest.
- Replacing KV token storage with another persistence mechanism.

---

## 7. Validation

- **Static first:** read `src/index.ts`, then `rg -n` the route names in the Swift app to
  confirm both ends agree.
- **Local run** (when secrets are available): `npx wrangler dev`.
- **Deploy** only when explicitly requested: `npx wrangler deploy`.
- TypeScript-only changes can be type-checked without deploying.

---

## User Instructions

For a human running or deploying the Worker.

### One-time setup
1. Authenticate Wrangler: `npx wrangler login`.
2. Create the KV namespaces and paste the ids into `wrangler.toml`:
   ```bash
   npx wrangler kv namespace create AUTH_TOKENS
   npx wrangler kv namespace create AUTH_TOKENS --preview
   ```
3. Create a [Resend](https://resend.com) account (sign up with the email you want links
   delivered to while testing without a domain) and an API key.
4. Store the secrets:
   ```bash
   npx wrangler secret put AZURE_OPENAI_API_KEY
   npx wrangler secret put COMPOSIO_API_KEY
   npx wrangler secret put RESEND_API_KEY
   ```

### Develop & deploy
- Local: `npx wrangler dev` (from `worker/`).
- Deploy: `npx wrangler deploy`.
- Logs: `npx wrangler tail` to watch live requests (the magic link is also logged here).

### Test the auth flow
- `POST /auth/magic-link` with `{ "email": "you@example.com" }` sends the email (and logs
  the link). Open the link → it redirects into `Macky://auth?token=…` → the app calls
  `POST /auth/verify` to exchange the token for a session.
