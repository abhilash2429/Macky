# AGENTS.md — worker/
<!-- Subfolder AGENTS.md. Rules here override root AGENTS.md for /worker scope only. -->

## Stack

- **Runtime**: Cloudflare Workers
- **Language**: TypeScript
- **Node**: 18+ (local dev only)
- **Package manager**: npm

## Commands

```bash
# Install dependencies
npm install

# Local dev (requires worker/.dev.vars with secrets)
npx wrangler dev

# Deploy to production
npx wrangler deploy

# Add/update secrets (never hardcode these)
npx wrangler secret put OPENAI_API_KEY
npx wrangler secret put COMPOSIO_API_KEY
```

## .dev.vars (local dev only — never commit this file)

```
OPENAI_API_KEY=sk-...
COMPOSIO_API_KEY=...
```

## Routes

| Route | Purpose |
|-------|---------|
| `GET /realtime` | WebSocket upgrade → proxy to OpenAI Realtime API |
| `POST /auth/magic-link` | Send magic link email for user auth |
| `POST /auth/verify` | Verify magic link token, return session |
| `POST /composio/connect` | Create Composio sub-user, return OAuth URL |

## Counterintuitive Conventions

**1. The Worker is a WebSocket proxy — it does zero computation.**
The `/realtime` route upgrades to WebSocket and forwards bytes between the Swift app and OpenAI's Realtime endpoint. It does not parse messages, modify payloads, or add logic. Any routing or model configuration is set at session initialization in the Swift client, not in the Worker.

**2. Cloudflare Workers have a 30s CPU time limit — proxying is exempt.**
Forwarding bytes does not count as CPU compute. Do not add message parsing, logging, or transformation to the proxy route — that would consume CPU and break long sessions.

**3. No state lives in the Worker.**
Workers are stateless per request. User sessions, Composio tokens, and OAuth state live in the Swift app's keychain (client-side) or in a persistent store (if needed). Do not add in-memory state to the Worker.

## Permission Tiers

**✅ Always do:**
- Validate that secrets exist before using them (check `env.OPENAI_API_KEY` is defined)
- Return appropriate HTTP status codes on errors

**⚠️ Ask before doing:**
- Adding a new route
- Adding an npm dependency
- Changing the WebSocket proxy logic

**🚫 Never do:**
- Hardcode API keys or secrets in source code
- Add computation to the WebSocket proxy route
- Commit `.dev.vars`