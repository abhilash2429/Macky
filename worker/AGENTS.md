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
| `GET /realtime` | WebSocket upgrade. Proxies bytes between the Swift client and the Azure AI Foundry realtime endpoint (`…/openai/v1/realtime?model=gpt-realtime-2.1`) using `AZURE_OPENAI_API_KEY`. Both sockets are wired together and torn down as a pair. |
| `GET /composio-config` | Requires `Authorization: Bearer <sessionToken>`. Resolves the caller's session (see §5), creates a Composio Tool Router session for that session's `composioUserId`, and returns `{ url, key }`, which the Swift client wires into the realtime `session.update` as an `mcp` tool entry. No `toolkits` allowlist is sent (full catalog via search); `manage_connections` is enabled with `enable_wait_for_connections: false` so a voice turn never blocks on OAuth. 401s with no/invalid session. |
| `POST /composio-connect` | Requires `Authorization: Bearer <sessionToken>`. Body/query `{ toolkit }`. Looks up an existing auth config for the toolkit (created in the Composio dashboard) and creates a hosted connect `link` for the session's `composioUserId`, with `callback_url` pointing at `/auth/connected` so the browser bounces back into the app after OAuth. Returns `{ toolkit, redirect_url }`. |
| `GET /composio-connections` | Requires `Authorization: Bearer <sessionToken>`. Lists the session's `composioUserId`'s ACTIVE connected accounts. Returns `{ connected: ["gmail", …] }`. |
| `POST /spotify-play` | Requires `Authorization: Bearer <sessionToken>`. Fast, direct "play a track by name" path. Body `{ query, uri? }`. Does SPOTIFY_SEARCH_FOR_ITEM → SPOTIFY_START_RESUME_PLAYBACK server-side in one hop for the session's `composioUserId` (via the Composio REST *execute* endpoint, not the MCP tool-router), targeting an active device when one exists and falling back to SPOTIFY_TRANSFER_PLAYBACK for an idle one. Returns `{ status:"playing", track, artist }`, or `{ needs_device:true, uri, … }` when Spotify has no awake device (the app opens Spotify locally and retries with the `uri`). Bypasses the slow model-driven MCP discovery chain that caused named-song playback to stall or silently no-op. Called by the `play_spotify_track` native tool. |
| `GET /dictation/realtime` | Requires `Authorization: Bearer <sessionToken>` and a WebSocket upgrade. The app first sends validated local `dictation.start` config (coarse surface kind, formatting mode, and up to 100 glossary keyterms). The Worker opens the already-deployed Azure `gpt-realtime-2.1-mini` model, configures a text-only 24 kHz session with no tools or tracing, and accepts only bounded `dictation.audio` chunks plus one `dictation.commit`. It never logs transcript frames, raw AX/browser metadata, or keyterms. |
| `POST /auth/magic-link` | Validates `{ email }`, stores a one-time token (`token → email`) in `AUTH_TOKENS` KV with a 15-minute TTL, and emails a clickable link via Resend. The link points at the https `/auth/open` endpoint (custom schemes aren't clickable in webmail). |
| `POST /auth/verify` | Consumes a magic-link token (single-use; deleted on first success), best-effort provisions the Composio user for that email, creates a `SESSIONS` record keyed by a fresh `sessionToken` with `composioUserId = email`, and returns `{ sessionToken, composioUserId }`. This **replaces** any anonymous session/identity the app was previously using — see §5. |
| `POST /auth/anonymous` | No auth required (this route *creates* identity). Mints a fresh no-login Composio identity (`composioUserId = "anon-<uuid>"`), provisions it, creates a `SESSIONS` record, and returns `{ sessionToken, composioUserId }` — same shape as `/auth/verify`. Called by the app on first run (or whenever it has no stored session), so connectors work with zero setup before/without email login. |
| `GET /auth/open?token=…` | Minimal HTML bridge that bounces the browser into the app via `Macky://auth?token=…`. Validates the token shape (UUID-ish) before reflecting it into the deep link. |
| `GET /auth/connected?toolkit=…` | The `callback_url` passed to `/composio-connect`'s link creation. Minimal HTML bridge (same pattern as `/auth/open`) that bounces the browser into the app via `Macky://connected?toolkit=…` once OAuth finishes, so the connectors grid can refresh immediately. |

---

## 3. Files

- `src/index.ts` — all route handlers and proxy logic.
- `wrangler.toml` — Worker name (`realtime-proxy`), entrypoint, compatibility date, the
  `AUTH_TOKENS` / `SESSIONS` KV namespace bindings, and the `MAGIC_LINK_FROM` /
  `PUBLIC_BASE_URL` vars.
- `.wrangler/` — local Wrangler state/cache. Do not commit secrets from local state.

---

## 4. Bindings, Secrets & Vars

**Secrets** (set with `npx wrangler secret put <NAME>`, never in source or `wrangler.toml`):

- `AZURE_OPENAI_API_KEY` — used by `/realtime` and `/dictation/realtime` to authenticate to Azure.
- `COMPOSIO_API_KEY` — used by `/composio-config` and Composio user provisioning.
- `RESEND_API_KEY` — used to deliver magic-link emails via the Resend HTTP API.

**KV namespaces:**

- `AUTH_TOKENS` — pending magic-link tokens (`token → email`), TTL'd via `expirationTtl`.
- `SESSIONS` — long-lived Composio sessions (`sessionToken → { composioUserId, kind,
  email? }`, JSON). No TTL — a session lives as long as the app's Keychain entry does.
  Populated by `/auth/anonymous` (`kind: "anonymous"`) and `/auth/verify`
  (`kind: "email"`). Every Composio route (`/composio-config`, `/composio-connect`,
  `/composio-connections`, `/spotify-play`) resolves the caller's identity from this via
  the `Authorization: Bearer <sessionToken>` header — there is no fixed/shared identity
  anymore.

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
- There is no fixed/shared Composio identity. Every Composio-facing route resolves
  `composioUserId` from the caller's `SESSIONS` record via `resolveSession()` — never
  hardcode a `user_id`, and never trust a client-supplied identity that hasn't been
  resolved through `SESSIONS`. This is a hosted, currently single-operator Worker;
  hardening this further (e.g. binding sessions to something less guessable, rate
  limiting `/auth/anonymous`) is a prerequisite before opening the Worker to many
  independent users.
- `/auth/anonymous` and `/auth/verify` are the only two ways a `SESSIONS` record is
  created, and both return the same `{ sessionToken, composioUserId }` shape. Logging in
  (`/auth/verify`) always mints a new session with `composioUserId = email` — it does not
  merge or migrate connected accounts from a prior anonymous session.
- Worker state is not durable except KV. Do not rely on module-level mutable state for
  sessions.
- Composio user provisioning (`provisionComposioUser`, used by both `/auth/verify` and
  `/auth/anonymous`) is best-effort: a Composio hiccup must not block login or the
  first-run bootstrap.
- Dictation has a deliberately separate authenticated WebSocket route. It opens only after local target validation, uses one short-lived text-only realtime session, and accepts no client event that could create a response with tools or audio. The Worker owns the Azure session configuration and closes the upstream session when the app closes its dictation socket.

---

## 6. Ask Before

- Adding or renaming a route.
- Changing the Azure realtime URL, the `model` query parameter, or the auth header.
- Changing the Composio session payload or returned config shape.
- Changing how `SESSIONS` records are created/resolved, or the `{ sessionToken,
  composioUserId }` response shape shared by `/auth/anonymous` and `/auth/verify`.
- Changing the magic-link email content, sender logic, or the `/auth/open` /
  `/auth/connected` redirect bridges.
- Adding npm dependencies or a package manifest.
- Replacing KV token storage with another persistence mechanism.

---

## 7. Validation

- **Static first:** read `src/index.ts`, then `rg -n` the route names in the Swift app to
  confirm both ends agree.
- **Local run** (when secrets are available): `npx wrangler dev`.
- **Deploy** only when explicitly requested: `npx wrangler deploy`.
- TypeScript-only changes can be type-checked without deploying.
- Dictation validation fixtures: `node --experimental-transform-types --test test/dictation-validation.test.ts`.

---

## User Instructions

For a human running or deploying the Worker.

### One-time setup
1. Authenticate Wrangler: `npx wrangler login`.
2. Create the KV namespaces and paste the ids into `wrangler.toml`:
   ```bash
   npx wrangler kv namespace create AUTH_TOKENS
   npx wrangler kv namespace create AUTH_TOKENS --preview
   npx wrangler kv namespace create SESSIONS
   npx wrangler kv namespace create SESSIONS --preview
   ```
3. Create a [Resend](https://resend.com) account (sign up with the email you want links
   delivered to while testing without a domain) and an API key.
4. Create a [Composio](https://app.composio.dev) project, grab its project API key, and
   (in the dashboard) create an auth config for each toolkit `ConnectorRegistry.swift`
   registers (gmail, slack, googlecalendar, notion, github, linear, spotify) —
   Composio-managed auth is fine to start. `/composio-connect` 404s for a toolkit with no
   auth config.
5. Store the secrets:
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
