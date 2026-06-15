export interface Env {
  AZURE_OPENAI_API_KEY: string;
  COMPOSIO_API_KEY: string;
  // Pending magic-link tokens: token -> email, 15-minute TTL.
  AUTH_TOKENS: KVNamespace;
}

/// Fixed Composio user for now. M14 (real per-user auth) swaps this one line.
const COMPOSIO_USER_ID = "auren-test-user";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/realtime") {
      return handleRealtimeProxy(request, env);
    }

    if (url.pathname === "/composio-config") {
      return handleComposioConfig(env);
    }

    if (url.pathname === "/auth/magic-link" && request.method === "POST") {
      return handleMagicLink(request, env);
    }

    if (url.pathname === "/auth/verify" && request.method === "POST") {
      return handleVerify(request, env);
    }

    return new Response("Not found", { status: 404 });
  },
};

/// Creates a fresh Composio Tool Router session for COMPOSIO_USER_ID and returns
/// the session's MCP URL plus the project API key, which the Swift client wires
/// into the Realtime `session.update` as an `mcp` tool entry.
///
/// No `toolkits` allowlist is sent, so the agent gets the full Composio catalog via
/// COMPOSIO_SEARCH_TOOLS. `manage_connections` lets the agent call
/// COMPOSIO_MANAGE_CONNECTIONS mid-turn to get a Connect Link for an app the user
/// hasn't authorized; `enable_wait_for_connections: false` so a voice turn never
/// blocks on the user finishing OAuth in the browser.
async function handleComposioConfig(env: Env): Promise<Response> {
  try {
    const sessionResponse = await fetch(
      "https://backend.composio.dev/api/v3.1/tool_router/session",
      {
        method: "POST",
        headers: {
          "x-api-key": env.COMPOSIO_API_KEY,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          user_id: COMPOSIO_USER_ID,
          manage_connections: {
            enable: true,
            enable_connection_removal: true,
            enable_wait_for_connections: false,
          },
        }),
      }
    );

    if (!sessionResponse.ok) {
      const body = await sessionResponse.text().catch(() => "");
      console.error(
        "Composio session create failed",
        sessionResponse.status,
        body
      );
      return new Response("Composio session create failed", { status: 500 });
    }

    const data = (await sessionResponse.json()) as { mcp?: { url?: string } };
    const mcpUrl = data.mcp?.url;

    if (!mcpUrl) {
      console.error("Composio session response missing mcp.url", data);
      return new Response("Composio session missing mcp url", { status: 500 });
    }

    return new Response(
      JSON.stringify({ url: mcpUrl, key: env.COMPOSIO_API_KEY }),
      { headers: { "Content-Type": "application/json" } }
    );
  } catch (err) {
    console.error("Composio config error", err);
    return new Response("Composio config error", { status: 500 });
  }
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/// POST /auth/magic-link — stores a one-time token (token -> email) in KV with a
/// 15-minute TTL and returns the `Speed://auth?token=…` deep link. No email is sent
/// yet: the link is logged and returned in the response so it can be tested by hand.
async function handleMagicLink(
  request: Request,
  env: Env
): Promise<Response> {
  let email: unknown;
  try {
    ({ email } = (await request.json()) as { email?: unknown });
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400);
  }

  if (typeof email !== "string" || !email.includes("@")) {
    return jsonResponse({ error: "A valid email is required" }, 400);
  }

  const token = crypto.randomUUID();
  // Token expires in 15 minutes (900s) — KV's minimum expirationTtl is 60s.
  await env.AUTH_TOKENS.put(token, email, { expirationTtl: 900 });

  const magicLink = `Speed://auth?token=${token}`;
  console.log("Magic link for", email, "→", magicLink);

  return jsonResponse({ ok: true, magicLink });
}

/// POST /auth/verify — validates a magic-link token, provisions the Composio user for
/// the email, and returns an opaque session token. Tokens are single-use: consumed on
/// the first successful verify.
async function handleVerify(request: Request, env: Env): Promise<Response> {
  let token: unknown;
  try {
    ({ token } = (await request.json()) as { token?: unknown });
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400);
  }

  if (typeof token !== "string" || token.length === 0) {
    return jsonResponse({ error: "A token is required" }, 400);
  }

  const email = await env.AUTH_TOKENS.get(token);
  if (!email) {
    return jsonResponse({ error: "Token is invalid or expired" }, 401);
  }

  // One-time use: consume the token so the link can't be replayed.
  await env.AUTH_TOKENS.delete(token);

  // Provision the Composio user for this email (best-effort — auth still succeeds
  // even if Composio is briefly unavailable; the user is re-provisioned on next use).
  await provisionComposioUser(email, env);

  const sessionJWT = crypto.randomUUID();
  return jsonResponse({ sessionJWT, composioUserId: email });
}

/// Ensures a Composio user/entity exists for `email` by opening a Tool Router session
/// with that `user_id` (Composio auto-provisions the entity on first use). Failures are
/// logged but not surfaced, so a Composio hiccup never blocks login.
async function provisionComposioUser(email: string, env: Env): Promise<void> {
  try {
    const response = await fetch(
      "https://backend.composio.dev/api/v3.1/tool_router/session",
      {
        method: "POST",
        headers: {
          "x-api-key": env.COMPOSIO_API_KEY,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ user_id: email }),
      }
    );
    if (!response.ok) {
      const body = await response.text().catch(() => "");
      console.error("Composio user provisioning failed", response.status, body);
    }
  } catch (err) {
    console.error("Composio user provisioning error", err);
  }
}

async function handleRealtimeProxy(
  request: Request,
  env: Env
): Promise<Response> {
  const upgrade = request.headers.get("Upgrade");

  if (upgrade?.toLowerCase() !== "websocket") {
    return new Response("Expected WebSocket upgrade", {
      status: 426,
    });
  }

  const azureUrl =
    "https://auren-resource.services.ai.azure.com/openai/v1/realtime?model=gpt-realtime-2";

  console.log("Connecting to Azure:", azureUrl);

  let azureResponse: Response;

  try {
    azureResponse = await fetch(azureUrl, {
      headers: {
        Upgrade: "websocket",
        "api-key": env.AZURE_OPENAI_API_KEY,
      },
    });
  } catch (err) {
    console.error("Azure fetch failed:", err);

    return new Response(
      `Azure connection failed: ${
        err instanceof Error ? err.message : String(err)
      }`,
      { status: 502 }
    );
  }

  console.log("Azure status:", azureResponse.status);

  if (azureResponse.status !== 101) {
    const body = await azureResponse.text().catch(() => "");

    console.error("Azure upgrade rejected");
    console.error("Status:", azureResponse.status);
    console.error("Body:", body);

    return new Response(
      `Azure websocket upgrade failed.\nStatus: ${azureResponse.status}\nBody: ${body}`,
      { status: 502 }
    );
  }

  const azureSocket = (azureResponse as any).webSocket;

  if (!azureSocket) {
    console.error("Azure returned 101 but no websocket object");

    return new Response(
      "Azure returned 101 but no websocket instance",
      { status: 502 }
    );
  }

  azureSocket.accept();

  const pair = new (globalThis as any).WebSocketPair();

  const clientSocket = pair[0];
  const workerSocket = pair[1];

  workerSocket.accept();

  let closed = false;

  function shutdown(code?: number, reason?: string) {
    if (closed) return;
    closed = true;

    try {
      workerSocket.close(code, reason);
    } catch {}

    try {
      azureSocket.close(code, reason);
    } catch {}
  }

  workerSocket.addEventListener("message", (event: MessageEvent) => {
    try {
      azureSocket.send(event.data);
    } catch (err) {
      console.error("Client -> Azure send failed", err);
      shutdown();
    }
  });

  azureSocket.addEventListener("message", (event: MessageEvent) => {
    try {
      workerSocket.send(event.data);
    } catch (err) {
      console.error("Azure -> Client send failed", err);
      shutdown();
    }
  });

  workerSocket.addEventListener("close", (event: CloseEvent) => {
    shutdown(event.code, event.reason);
  });

  azureSocket.addEventListener("close", (event: CloseEvent) => {
    shutdown(event.code, event.reason);
  });

  workerSocket.addEventListener("error", (err: Event) => {
    console.error("Client socket error", err);
    shutdown();
  });

  azureSocket.addEventListener("error", (err: Event) => {
    console.error("Azure socket error", err);
    shutdown();
  });

  return new Response(null, {
    status: 101,
    webSocket: clientSocket,
  } as any);
}