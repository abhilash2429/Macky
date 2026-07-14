export interface Env {
  AZURE_OPENAI_API_KEY: string;
  // Used only by the on-demand AssemblyAI dictation proxy. This secret never
  // reaches the macOS app; each held Ctrl + Fn dictation opens one short-lived
  // upstream streaming session and explicitly terminates it on release.
  ASSEMBLYAI_API_KEY: string;
  COMPOSIO_API_KEY: string;
  // Pending magic-link tokens: token -> email, 15-minute TTL.
  AUTH_TOKENS: KVNamespace;
  // Long-lived Composio sessions: sessionToken -> ComposioSession (JSON). Created by
  // /auth/anonymous (first-run, no login) and /auth/verify (email login). No TTL —
  // a session lives as long as the app's Keychain entry does.
  SESSIONS: KVNamespace;
  // Resend API key, used to deliver magic-link emails. No domain required: with
  // the shared onboarding@resend.dev sender, Resend delivers to the address you
  // signed up with. Set as a secret: `npx wrangler secret put RESEND_API_KEY`.
  RESEND_API_KEY: string;
  // Sender for magic-link emails. Default onboarding@resend.dev works with no
  // domain; switch to an address on your own verified Resend domain later.
  MAGIC_LINK_FROM: string;
  // Public origin of this Worker, used to build the clickable https link in the
  // email (e.g. https://realtime-proxy.speedmac.workers.dev).
  PUBLIC_BASE_URL: string;
  // Azure deployment used only when the user explicitly selects Smart dictation
  // polishing. Literal and Clean modes never call Azure.
  DICTATION_POLISH_MODEL?: string;
  // Development-only acknowledgement. AssemblyAI zero retention is an account
  // setting, not an API request option; production deployment must flip this
  // flag only after the paid-account opt-out is configured.
  DICTATION_PRIVACY_MODE?: string;
  DICTATION_ZERO_RETENTION_CONFIRMED?: string;
}

/// A Composio identity bound to an opaque `sessionToken` the app carries in the
/// `Authorization: Bearer …` header. Two kinds:
///   - "anonymous": minted on first run (or whenever the app has no session yet) via
///     POST /auth/anonymous, with no login required. `composioUserId` is a random
///     `anon-<uuid>`.
///   - "email": minted by POST /auth/verify after a magic-link login. `composioUserId`
///     is the user's email, so it's stable across reinstalls/devices.
/// Logging in replaces any existing anonymous session with an email one; toolkits
/// connected under the old anonymous identity are not migrated (Composio has no
/// cross-user account transfer) — the user reconnects them under the email identity.
interface ComposioSession {
  composioUserId: string;
  kind: "anonymous" | "email";
  email?: string;
  createdAt: string;
}

/// Resolves the caller's Composio session from the `Authorization: Bearer <sessionToken>`
/// header. Returns null (→ callers should 401) when the header is missing, malformed, or
/// the token isn't in SESSIONS (never issued, or the KV was wiped).
async function resolveSession(request: Request, env: Env): Promise<ComposioSession | null> {
  const authHeader = request.headers.get("Authorization") ?? "";
  const match = /^Bearer\s+(.+)$/i.exec(authHeader.trim());
  const token = match?.[1]?.trim();
  if (!token) return null;
  const raw = await env.SESSIONS.get(token);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as ComposioSession;
  } catch {
    return null;
  }
}

/// Creates and persists a new Composio session, provisioning the Composio user
/// (best-effort) so it's ready to use immediately. Shared by /auth/anonymous and
/// /auth/verify so both produce the same `{ sessionToken, composioUserId }` shape.
async function createSession(
  composioUserId: string,
  kind: ComposioSession["kind"],
  env: Env,
  email?: string
): Promise<{ sessionToken: string; composioUserId: string }> {
  await provisionComposioUser(composioUserId, env);
  const sessionToken = crypto.randomUUID();
  const session: ComposioSession = {
    composioUserId,
    kind,
    email,
    createdAt: new Date().toISOString(),
  };
  await env.SESSIONS.put(sessionToken, JSON.stringify(session));
  return { sessionToken, composioUserId };
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/realtime") {
      return handleRealtimeProxy(request, env);
    }

    if (url.pathname === "/composio-config") {
      return handleComposioConfig(request, env);
    }

    if (url.pathname === "/composio-connect") {
      return handleComposioConnect(request, url, env);
    }

    if (url.pathname === "/composio-connections") {
      return handleComposioConnections(request, env);
    }

    if (url.pathname === "/spotify-play" && request.method === "POST") {
      return handleSpotifyPlay(request, env);
    }

    if (url.pathname === "/dictation/assemblyai") {
      return handleAssemblyAIDictationProxy(request, env);
    }

    if (url.pathname === "/dictation/polish" && request.method === "POST") {
      return handleDictationPolish(request, env);
    }

    if (url.pathname === "/auth/magic-link" && request.method === "POST") {
      return handleMagicLink(request, env);
    }

    if (url.pathname === "/auth/verify" && request.method === "POST") {
      return handleVerify(request, env);
    }

    // First-run / no-login Composio identity. Called by the app whenever it has no
    // stored session yet, so connectors work immediately without requiring email auth.
    if (url.pathname === "/auth/anonymous" && request.method === "POST") {
      return handleAnonymousAuth(env);
    }

    // Clickable https link from the email; bounces the browser into the app via
    // the Macky:// custom scheme. Custom-scheme links aren't clickable in Gmail,
    // so the email always points here instead.
    if (url.pathname === "/auth/open" && request.method === "GET") {
      return handleAuthOpen(url);
    }

    // Composio's OAuth callback_url after a connector finishes linking. Bounces the
    // browser back into the app so it can refresh the connectors grid immediately.
    if (url.pathname === "/auth/connected" && request.method === "GET") {
      return handleAuthConnected(url);
    }

    return new Response("Not found", { status: 404 });
  },
};

/// Creates a fresh Composio Tool Router session for the caller's resolved Composio
/// identity (see `resolveSession`) and returns the session's MCP URL plus the project
/// API key, which the Swift client wires into the Realtime `session.update` as an
/// `mcp` tool entry.
///
/// No `toolkits` allowlist is sent, so the agent gets the full Composio catalog via
/// COMPOSIO_SEARCH_TOOLS. `manage_connections` lets the agent call
/// COMPOSIO_MANAGE_CONNECTIONS mid-turn to get a Connect Link for an app the user
/// hasn't authorized; `enable_wait_for_connections: false` so a voice turn never
/// blocks on the user finishing OAuth in the browser.
async function handleComposioConfig(request: Request, env: Env): Promise<Response> {
  const session = await resolveSession(request, env);
  if (!session) {
    return jsonResponse({ error: "missing or invalid session" }, 401);
  }

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
          user_id: session.composioUserId,
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

/// Initiates a Composio connection for a toolkit and returns the OAuth redirect
/// URL directly, so the app can open it without routing through the realtime voice
/// model (which would narrate filler). Two steps, both Composio-managed:
///   1. Look up an auth config for the toolkit slug (created in the Composio dashboard).
///   2. Create a hosted connection `link` for the caller's resolved Composio identity
///      (see `resolveSession`) → redirect URL.
///
/// Body/query: `toolkit` (slug, e.g. "spotify"). Requires `Authorization: Bearer
/// <sessionToken>`. Returns `{ toolkit, redirect_url }`.
async function handleComposioConnect(
  request: Request,
  url: URL,
  env: Env
): Promise<Response> {
  const session = await resolveSession(request, env);
  if (!session) {
    return jsonResponse({ error: "missing or invalid session" }, 401);
  }

  try {
    // Accept the toolkit slug from a POST JSON body or a ?toolkit= query param.
    let toolkit = url.searchParams.get("toolkit") ?? "";
    if (!toolkit && request.method === "POST") {
      const body = (await request.json().catch(() => ({}))) as {
        toolkit?: string;
      };
      toolkit = body.toolkit ?? "";
    }
    toolkit = toolkit.trim().toLowerCase();
    if (!toolkit) {
      return jsonResponse({ error: "missing toolkit" }, 400);
    }

    const headers = {
      "x-api-key": env.COMPOSIO_API_KEY,
      "Content-Type": "application/json",
    };

    // 1. Find an auth config for this toolkit (created in the Composio dashboard).
    const authConfigResponse = await fetch(
      `https://backend.composio.dev/api/v3/auth_configs?toolkit_slug=${encodeURIComponent(
        toolkit
      )}`,
      { method: "GET", headers }
    );
    if (!authConfigResponse.ok) {
      const body = await authConfigResponse.text().catch(() => "");
      console.error("Composio auth_configs lookup failed", authConfigResponse.status, body);
      return jsonResponse({ error: "auth config lookup failed" }, 502);
    }
    const authConfigData = (await authConfigResponse.json()) as {
      items?: Array<{ id?: string }>;
      data?: Array<{ id?: string }>;
    };
    const authConfigId =
      authConfigData.items?.[0]?.id ?? authConfigData.data?.[0]?.id;
    if (!authConfigId) {
      console.error("No auth config for toolkit", toolkit, authConfigData);
      return jsonResponse({ error: "no auth config for toolkit" }, 404);
    }

    // 2. Create a hosted connection link → OAuth redirect URL for the user. The
    //    callback_url bounces the browser back into the app once OAuth finishes, so
    //    the connectors grid can refresh immediately instead of waiting on the user
    //    to switch back manually.
    const callbackUrl = `${env.PUBLIC_BASE_URL.replace(/\/$/, "")}/auth/connected?toolkit=${encodeURIComponent(toolkit)}`;
    const linkResponse = await fetch(
      "https://backend.composio.dev/api/v3/connected_accounts/link",
      {
        method: "POST",
        headers,
        body: JSON.stringify({
          user_id: session.composioUserId,
          auth_config_id: authConfigId,
          callback_url: callbackUrl,
        }),
      }
    );
    if (!linkResponse.ok) {
      const body = await linkResponse.text().catch(() => "");
      console.error("Composio connect link failed", linkResponse.status, body);
      return jsonResponse({ error: "connect link failed" }, 502);
    }
    const linkData = (await linkResponse.json()) as Record<string, unknown>;
    const redirectURL =
      (linkData["redirect_url"] as string | undefined) ??
      (linkData["redirectUrl"] as string | undefined) ??
      (linkData["redirect_uri"] as string | undefined) ??
      ((linkData["connectionData"] as Record<string, unknown> | undefined)?.[
        "redirect_url"
      ] as string | undefined);
    if (!redirectURL) {
      console.error("Composio link response missing redirect url", linkData);
      return jsonResponse({ error: "missing redirect url" }, 502);
    }

    return jsonResponse({ toolkit, redirect_url: redirectURL });
  } catch (err) {
    console.error("Composio connect error", err);
    return jsonResponse({ error: "composio connect error" }, 500);
  }
}

/// Lists the toolkits the user currently has an ACTIVE connection to, so the app
/// can show a "connected" (live) tick on those connectors instead of a connect
/// prompt. Requires `Authorization: Bearer <sessionToken>`. Returns
/// `{ connected: ["gmail", ...] }` (lowercased toolkit slugs).
async function handleComposioConnections(request: Request, env: Env): Promise<Response> {
  const session = await resolveSession(request, env);
  if (!session) {
    return jsonResponse({ error: "missing or invalid session" }, 401);
  }

  try {
    const response = await fetch(
      `https://backend.composio.dev/api/v3/connected_accounts?user_ids=${encodeURIComponent(
        session.composioUserId
      )}&statuses=ACTIVE&limit=100`,
      {
        method: "GET",
        headers: {
          "x-api-key": env.COMPOSIO_API_KEY,
          "Content-Type": "application/json",
        },
      }
    );
    if (!response.ok) {
      const body = await response.text().catch(() => "");
      console.error("Composio connected_accounts list failed", response.status, body);
      return jsonResponse({ error: "connected accounts list failed" }, 502);
    }
    const data = (await response.json()) as {
      items?: Array<{ status?: string; toolkit?: { slug?: string } }>;
    };
    const connected = Array.from(
      new Set(
        (data.items ?? [])
          .filter((item) => (item.status ?? "").toUpperCase() === "ACTIVE")
          .map((item) => item.toolkit?.slug?.toLowerCase())
          .filter((slug): slug is string => !!slug)
      )
    );
    return jsonResponse({ connected });
  } catch (err) {
    console.error("Composio connections error", err);
    return jsonResponse({ error: "composio connections error" }, 500);
  }
}

/// Executes a single Composio tool for `composioUserId` via the REST execute
/// endpoint and returns the parsed `{ successful, data, error }` envelope. This is
/// the *direct* path (no MCP tool-router discovery), so it's one hop with no voice
/// model in the loop — the whole point of the fast Spotify route below.
async function composioExecute(
  env: Env,
  composioUserId: string,
  slug: string,
  args: Record<string, unknown>
): Promise<{ successful: boolean; data: any; error: unknown }> {
  const response = await fetch(
    `https://backend.composio.dev/api/v3/tools/execute/${slug}`,
    {
      method: "POST",
      headers: {
        "x-api-key": env.COMPOSIO_API_KEY,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ user_id: composioUserId, arguments: args }),
    }
  );
  if (!response.ok) {
    const body = await response.text().catch(() => "");
    console.error("Composio execute failed", slug, response.status, body);
    return { successful: false, data: null, error: `execute ${slug} ${response.status}` };
  }
  const json = (await response.json()) as {
    successful?: boolean;
    data?: unknown;
    error?: unknown;
  };
  return {
    successful: json.successful === true,
    data: json.data ?? null,
    error: json.error ?? null,
  };
}

/// True when a Composio START_RESUME_PLAYBACK failure is Spotify's NO_ACTIVE_DEVICE
/// (or the follow-on "Device not found" when a device_id was passed for an idle
/// client). Both mean: nothing is awake to play on — the app must open Spotify
/// locally first, then retry. Detected by string match because Composio nests the
/// raw Spotify error as JSON text inside `error`/`data`.
function isNoActiveDevice(result: { error: unknown; data: any }): boolean {
  const blob = JSON.stringify(result.error ?? "") + JSON.stringify(result.data ?? "");
  return (
    blob.includes("NO_ACTIVE_DEVICE") ||
    blob.includes("No active device") ||
    blob.includes("Device not found")
  );
}

/// POST /spotify-play — the fast, direct "play a track by name" path. Does the whole
/// search→play chain server-side in one request (no MCP tool-router discovery, no
/// voice model driving multiple hops), so the app calls one native tool and gets one
/// clean result.
///
/// Body: `{ query: string }` (e.g. "blinding lights the weeknd").
/// Steps:
///   1. SPOTIFY_SEARCH_FOR_ITEM → top track URI + name/artist.
///   2. SPOTIFY_GET_AVAILABLE_DEVICES → pick an active device_id if one exists.
///   3. SPOTIFY_START_RESUME_PLAYBACK with that URI (and device_id when known).
///
/// Returns:
///   • `{ status: "playing", track, artist }` on success.
///   • `{ needs_device: true, track, artist, query }` when Spotify has no awake device
///     — the app opens Spotify locally and retries. NEVER a fake success: the whole
///     "says playing but nothing plays" bug was the old path reporting success here.
///   • `{ error }` when the search finds nothing or a call hard-fails.
async function handleSpotifyPlay(request: Request, env: Env): Promise<Response> {
  const session = await resolveSession(request, env);
  if (!session) {
    return jsonResponse({ error: "missing or invalid session" }, 401);
  }

  let query = "";
  let knownUri = "";
  try {
    const body = (await request.json()) as { query?: unknown; uri?: unknown };
    query = typeof body.query === "string" ? body.query.trim() : "";
    // On a retry (after the app opened Spotify locally), the URI from the first
    // call is passed back so we skip the redundant search.
    knownUri = typeof body.uri === "string" ? body.uri.trim() : "";
  } catch {
    return jsonResponse({ error: "invalid JSON body" }, 400);
  }
  if (!query && !knownUri) {
    return jsonResponse({ error: "missing query" }, 400);
  }

  try {
    let uri = knownUri;
    let trackName = "";
    let artist = "";

    // 1. Search for the best-matching track (skipped when a URI was carried over
    //    from a prior needs_device response).
    if (!uri) {
      const search = await composioExecute(env, session.composioUserId, "SPOTIFY_SEARCH_FOR_ITEM", {
        q: query,
        type: ["track"],
        limit: 1,
      });
      if (!search.successful) {
        console.error("Spotify search failed", JSON.stringify(search.error));
        return jsonResponse({ error: "search failed" }, 502);
      }
      const track = search.data?.tracks?.items?.[0];
      uri = track?.uri ?? "";
      if (!uri) {
        return jsonResponse({ error: "no track found", query });
      }
      trackName = track?.name ?? "";
      artist = (track?.artists ?? [])
        .map((a: { name?: string }) => a?.name)
        .filter(Boolean)
        .join(", ");
    }

    // 2. Find a device to target. Prefer an already-active device; if the only
    //    devices are idle, we still capture one to try a transfer below. Spotify
    //    won't start on a fully-idle client without help.
    const devicesResult = await composioExecute(
      env,
      session.composioUserId,
      "SPOTIFY_GET_AVAILABLE_DEVICES",
      {}
    );
    const devices: Array<{ id?: string; is_active?: boolean }> =
      devicesResult.data?.devices ?? [];
    const activeDevice = devices.find((d) => d.is_active);
    const idleDevice = devices.find((d) => d.id);

    // 3. Start playback. Only pass device_id for an active device — passing it for
    //    an idle one returns "Device not found" (verified).
    const play = await startPlayback(
      env,
      session.composioUserId,
      uri,
      activeDevice?.is_active ? activeDevice.id : undefined
    );
    if (play.successful) {
      return jsonResponse({ status: "playing", track: trackName, artist, uri });
    }

    // 3b. No active device, but a known (idle) device exists — e.g. a phone that's
    //    logged in but asleep. Transfer playback to it (play:true wakes it), then
    //    the transfer itself starts the track context. This is the "any device"
    //    fallback for when the Mac has no Spotify app to open.
    if (isNoActiveDevice(play) && idleDevice?.id) {
      const transfer = await composioExecute(env, session.composioUserId, "SPOTIFY_TRANSFER_PLAYBACK", {
        device_ids: [idleDevice.id],
        play: true,
      });
      if (transfer.successful) {
        const retry = await startPlayback(env, session.composioUserId, uri, idleDevice.id);
        if (retry.successful) {
          return jsonResponse({ status: "playing", track: trackName, artist, uri });
        }
      }
    }

    if (isNoActiveDevice(play)) {
      // Nothing awake anywhere. Tell the app to open Spotify locally and call again
      // with the resolved URI. NEVER a fake success — that was the original bug.
      return jsonResponse({ needs_device: true, track: trackName, artist, uri, query });
    }

    console.error("Spotify play failed", JSON.stringify(play.error));
    return jsonResponse({ error: "play failed" }, 502);
  } catch (err) {
    console.error("Spotify play error", err);
    return jsonResponse({ error: "spotify play error" }, 500);
  }
}

/// Thin wrapper around SPOTIFY_START_RESUME_PLAYBACK: plays `uri`, optionally on a
/// specific `deviceId`. Split out so the search path and the transfer-retry path
/// share one call site.
async function startPlayback(
  env: Env,
  composioUserId: string,
  uri: string,
  deviceId?: string
): Promise<{ successful: boolean; data: any; error: unknown }> {
  const args: Record<string, unknown> = { uris: [uri] };
  if (deviceId) {
    args.device_id = deviceId;
  }
  return composioExecute(env, composioUserId, "SPOTIFY_START_RESUME_PLAYBACK", args);
}


interface DictationStartMessage {
  type: "dictation.start";
  keyterms: string[];
  surfaceKind: DictationSurfaceKind;
  formattingMode: "literal" | "clean" | "smart";
}

const assemblyAIStreamingTokenLifetimeSeconds = 60;
const assemblyAIDictationMaximumSessionSeconds = 120;

/// Opens one AssemblyAI session per held dictation. `/realtime` deliberately stays
/// a byte-forwarding Azure proxy; this separate route owns the explicit
/// `Terminate` lifecycle required by AssemblyAI's per-open-session billing.
async function handleAssemblyAIDictationProxy(request: Request, env: Env): Promise<Response> {
  if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
    return new Response("Expected WebSocket upgrade", { status: 426 });
  }
  if (!env.ASSEMBLYAI_API_KEY) {
    return new Response("Dictation transcription is not configured", { status: 503 });
  }
  if (env.DICTATION_PRIVACY_MODE === "production" && env.DICTATION_ZERO_RETENTION_CONFIRMED !== "true") {
    // Zero retention is configured at the AssemblyAI account level. This route
    // refuses a production label until a deployment operator has performed that
    // account-level release check instead of implying an API flag can enforce it.
    return new Response("AssemblyAI production privacy configuration is not verified", { status: 503 });
  }
  if (!(await resolveSession(request, env))) {
    return new Response("Missing or invalid session", { status: 401 });
  }

  const pair = new (globalThis as any).WebSocketPair();
  const clientSocket = pair[0] as WebSocket;
  const workerSocket = pair[1] as WebSocket;
  workerSocket.accept();

  let upstreamSocket: WebSocket | undefined;
  let isStarting = false;
  let isClosed = false;
  let isTerminationRequested = false;
  let isTerminationForwarded = false;
  let startDeadline: ReturnType<typeof setTimeout> | undefined;
  let terminationDeadline: ReturnType<typeof setTimeout> | undefined;

  const clearDeadlines = () => {
    if (startDeadline) clearTimeout(startDeadline);
    if (terminationDeadline) clearTimeout(terminationDeadline);
    startDeadline = undefined;
    terminationDeadline = undefined;
  };

  const closeBoth = (code = 1000, reason = "") => {
    if (isClosed) return;
    isClosed = true;
    clearDeadlines();
    try { workerSocket.close(code, reason); } catch {}
    try { upstreamSocket?.close(code, reason); } catch {}
  };

  const sendWorkerError = (error: string) => {
    if (isClosed) return;
    try { workerSocket.send(JSON.stringify({ type: "Error", error })); } catch {}
  };

  const terminateUpstream = () => {
    if (!upstreamSocket || isTerminationForwarded || isClosed) {
      closeBoth();
      return;
    }
    isTerminationForwarded = true;
    try {
      upstreamSocket.send(JSON.stringify({ type: "Terminate" }));
    } catch {
      closeBoth();
      return;
    }

    // The provider normally follows `Terminate` with final Turn data and a
    // `Termination` message. Do not leave a session billable if that exchange is
    // interrupted; without a verified final transcript the macOS client inserts
    // nothing and offers its safe Copy path instead.
    terminationDeadline = setTimeout(() => closeBoth(1001, "dictation termination timed out"), 4_000);
  };

  const openUpstream = async (start: DictationStartMessage) => {
    try {
      if (!isAssemblyAIUpstreamOpeningAllowed(isClosed, isTerminationRequested)) {
        closeBoth();
        return;
      }
      const streamingToken = await createAssemblyAIStreamingToken(env);
      // Release can arrive while the temporary-token request is in flight. Do
      // not open an upstream socket after that release: AssemblyAI bills from
      // socket open time, including silence.
      if (!isAssemblyAIUpstreamOpeningAllowed(isClosed, isTerminationRequested)) {
        closeBoth();
        return;
      }

      const upstreamURL = new URL("https://streaming.assemblyai.com/v3/ws");
      upstreamURL.searchParams.set("sample_rate", "16000");
      upstreamURL.searchParams.set("speech_model", "universal-3-5-pro");
      upstreamURL.searchParams.set("mode", "balanced");
      upstreamURL.searchParams.set("token", streamingToken);
      upstreamURL.searchParams.set("prompt", assemblyAIDictationPrompt(start.surfaceKind));
      if (start.keyterms.length > 0) {
        upstreamURL.searchParams.set("keyterms_prompt", JSON.stringify(start.keyterms));
      }

      const upstreamResponse = await fetch(upstreamURL.toString(), {
        headers: { Upgrade: "websocket" },
      });
      if (upstreamResponse.status !== 101) {
        sendWorkerError("AssemblyAI streaming connection was rejected");
        closeBoth(1011, "AssemblyAI streaming connection rejected");
        return;
      }

      const socket = (upstreamResponse as any).webSocket as WebSocket | undefined;
      if (!socket) {
        sendWorkerError("AssemblyAI did not return a streaming socket");
        closeBoth(1011, "AssemblyAI streaming socket unavailable");
        return;
      }

      upstreamSocket = socket;
      socket.accept();
      socket.addEventListener("message", (event: MessageEvent) => {
        try {
          // The Worker never parses or logs transcript content. It forwards the
          // provider's text/binary frames unchanged to the authenticated app.
          workerSocket.send(event.data);
        } catch {
          terminateUpstream();
        }
      });
      socket.addEventListener("close", (event: CloseEvent) => closeBoth(event.code, event.reason));
      socket.addEventListener("error", () => {
        sendWorkerError("AssemblyAI streaming connection failed");
        closeBoth(1011, "AssemblyAI streaming connection failed");
      });

      if (isTerminationRequested) terminateUpstream();
    } catch {
      if (isTerminationRequested) {
        closeBoth();
        return;
      }
      sendWorkerError("AssemblyAI streaming connection failed");
      closeBoth(1011, "AssemblyAI streaming connection failed");
    }
  };

  workerSocket.addEventListener("message", (event: MessageEvent) => {
    if (isClosed) return;

    if (!isStarting) {
      const start = parseDictationStartMessage(event.data);
      if (!start) {
        sendWorkerError("Dictation must begin with valid local configuration");
        closeBoth(1008, "invalid dictation configuration");
        return;
      }
      isStarting = true;
      if (startDeadline) clearTimeout(startDeadline);
      void openUpstream(start);
      return;
    }

    if (!upstreamSocket) {
      if (isTerminateMessage(event.data)) isTerminationRequested = true;
      return;
    }

    if (isTerminateMessage(event.data)) {
      isTerminationRequested = true;
      terminateUpstream();
      return;
    }
    try {
      upstreamSocket.send(event.data);
    } catch {
      closeBoth(1011, "could not forward dictation audio");
    }
  });

  workerSocket.addEventListener("close", () => terminateUpstream());
  workerSocket.addEventListener("error", () => terminateUpstream());

  // A client that opens the route but never sends a local target-safe start
  // message never creates an AssemblyAI session and therefore never incurs ASR cost.
  startDeadline = setTimeout(() => closeBoth(1008, "dictation start timed out"), 5_000);

  return new Response(null, { status: 101, webSocket: clientSocket } as any);
}

export function isAssemblyAIUpstreamOpeningAllowed(
  isClosed: boolean,
  isTerminationRequested: boolean,
): boolean {
  return !isClosed && !isTerminationRequested;
}

async function createAssemblyAIStreamingToken(env: Env): Promise<string> {
  const tokenURL = new URL("https://streaming.assemblyai.com/v3/token");
  tokenURL.searchParams.set("expires_in_seconds", String(assemblyAIStreamingTokenLifetimeSeconds));
  tokenURL.searchParams.set("max_session_duration_seconds", String(assemblyAIDictationMaximumSessionSeconds));
  const response = await fetch(tokenURL.toString(), {
    headers: { Authorization: env.ASSEMBLYAI_API_KEY },
  });
  if (!response.ok) throw new Error("AssemblyAI temporary-token request failed");
  const body = (await response.json()) as { token?: unknown };
  if (typeof body.token !== "string" || !body.token) {
    throw new Error("AssemblyAI temporary-token response was invalid");
  }
  return body.token;
}

export function parseDictationStartMessage(value: unknown): DictationStartMessage | null {
  if (typeof value !== "string") return null;
  let body: { type?: unknown; keyterms?: unknown; surface_kind?: unknown; formatting_mode?: unknown };
  try {
    body = JSON.parse(value) as typeof body;
  } catch {
    return null;
  }
  if (body.type !== "dictation.start" || !isDictationSurfaceKind(body.surface_kind)) return null;
  if (body.formatting_mode !== "literal" && body.formatting_mode !== "clean" && body.formatting_mode !== "smart") return null;
  return {
    type: "dictation.start",
    keyterms: sanitizeDictationKeyterms(body.keyterms),
    surfaceKind: body.surface_kind,
    formattingMode: body.formatting_mode,
  };
}

export function sanitizeDictationKeyterms(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  const unique = new Set<string>();
  for (const term of value) {
    if (typeof term !== "string") continue;
    const trimmed = term.trim();
    if (!trimmed || trimmed.length > 50) continue;
    unique.add(trimmed);
    if (unique.size === 100) break;
  }
  return [...unique];
}

function isDictationSurfaceKind(value: unknown): value is DictationSurfaceKind {
  return value === "email" || value === "chat" || value === "document" || value === "code" || value === "terminal" || value === "generic";
}

function isTerminateMessage(value: unknown): boolean {
  if (typeof value !== "string") return false;
  try {
    return (JSON.parse(value) as { type?: unknown }).type === "Terminate";
  } catch {
    return false;
  }
}

function assemblyAIDictationPrompt(surfaceKind: DictationSurfaceKind): string {
  switch (surfaceKind) {
  case "email": return "Short desktop email dictation.";
  case "chat": return "Short desktop chat dictation.";
  case "document": return "Desktop document dictation.";
  case "code": return "Desktop software-development dictation.";
  case "terminal": return "Desktop terminal command dictation.";
  case "generic": return "Short desktop dictation.";
  }
}

async function handleDictationPolish(request: Request, env: Env): Promise<Response> {
  const session = await resolveSession(request, env);
  if (!session) return jsonResponse({ error: "missing or invalid session" }, 401);

  let body: {
    transcript?: unknown;
    surface_kind?: unknown;
    formatting_mode?: unknown;
    has_selection?: unknown;
    is_terminal?: unknown;
  };
  try {
    body = (await request.json()) as typeof body;
  } catch {
    return jsonResponse({ error: "invalid JSON body" }, 400);
  }

  const transcript = typeof body.transcript === "string" ? body.transcript : "";
  if (!transcript.trim() || transcript.length > 16_000) {
    return jsonResponse({ error: "missing or invalid transcript" }, 400);
  }
  if (!isDictationSurfaceKind(body.surface_kind) || body.formatting_mode !== "smart") {
    return jsonResponse({ error: "invalid dictation formatting request" }, 400);
  }
  if (typeof body.has_selection !== "boolean" || typeof body.is_terminal !== "boolean") {
    return jsonResponse({ error: "invalid dictation safety flags" }, 400);
  }

  const safetyIdentifier = await safetyIdentifierForSession(session);
  const response = await fetch("https://abhilashreddymand-0825-resource.services.ai.azure.com/openai/v1/responses", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "api-key": env.AZURE_OPENAI_API_KEY,
    },
    body: JSON.stringify({
      model: env.DICTATION_POLISH_MODEL || "gpt-5.6-luna",
      store: false,
      safety_identifier: safetyIdentifier,
      instructions: dictationPolishInstructions(body.surface_kind, body.is_terminal),
      input: transcript,
      text: {
        verbosity: "low",
        format: {
          type: "json_schema",
          name: "dictation_polish",
          strict: true,
          schema: {
            type: "object",
            additionalProperties: false,
            properties: { text: { type: "string" } },
            required: ["text"],
          },
        },
      },
      reasoning: { effort: "none" },
      max_output_tokens: 2_000,
    }),
  });
  if (!response.ok) return jsonResponse({ error: "dictation polish failed" }, 502);

  let outputText = "";
  try {
    const payload = (await response.json()) as {
      output_text?: unknown;
      output?: Array<{ content?: Array<{ type?: unknown; text?: unknown; refusal?: unknown }> }>;
    };
    if (typeof payload.output_text === "string") {
      outputText = payload.output_text;
    } else {
      outputText = (payload.output ?? [])
        .flatMap((item) => item.content ?? [])
        .filter((part) => part.type === "output_text" && typeof part.text === "string")
        .map((part) => part.text as string)
        .join("\n");
    }
  } catch {
    return jsonResponse({ error: "dictation polish response was unreadable" }, 502);
  }

  let polished: { text?: unknown };
  try {
    polished = JSON.parse(outputText) as typeof polished;
  } catch {
    return jsonResponse({ error: "dictation polish returned invalid structured output" }, 502);
  }
  if (typeof polished.text !== "string" || !polished.text.trim() || polished.text.length > 20_000) {
    return jsonResponse({ error: "dictation polish returned invalid text" }, 502);
  }
  return jsonResponse({ text: polished.text });
}

function dictationPolishInstructions(surfaceKind: DictationSurfaceKind, isTerminal: boolean): string {
  const surfaceRule = isTerminal || surfaceKind === "terminal" || surfaceKind === "code"
    ? "Use literal-first formatting. Preserve syntax, identifiers, punctuation, whitespace commands, and code exactly."
    : surfaceKind === "email"
      ? "Use polished email paragraphs, but never invent a subject, recipient, greeting, or sign-off."
      : surfaceKind === "chat"
        ? "Use concise conversational prose."
        : surfaceKind === "document"
          ? "Use paragraphs and bullets only when explicitly spoken."
          : "Use natural punctuation and remove only unmistakable disfluencies or false starts. Never remove a meaningful word such as like.";
  return `Return only JSON matching the schema. Polish this one dictated result without adding actions or commentary. Never invent, remove, or alter facts, names, numbers, dates, URLs, email addresses, code, recipients, greetings, or sign-offs. Render explicit spoken commands such as new paragraph, new line, bullet, comma, and period when they are clearly commands. ${surfaceRule}`;
}

async function safetyIdentifierForSession(session: ComposioSession): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(session.composioUserId)
  );
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/// POST /auth/magic-link — stores a one-time token (token -> email) in KV with a
/// 15-minute TTL and emails the user a clickable link that opens the app. The link
/// points at the https `/auth/open` endpoint (custom Macky:// schemes aren't
/// clickable in webmail) which redirects into `Macky://auth?token=…`.
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

  const base = (env.PUBLIC_BASE_URL || new URL(request.url).origin).replace(
    /\/$/,
    ""
  );
  const clickableLink = `${base}/auth/open?token=${token}`;
  console.log("Magic link for", email, "→", clickableLink);

  try {
    await sendMagicLinkEmail(email, clickableLink, env);
  } catch (err) {
    console.error("Magic link email send failed", err);
    return jsonResponse({ error: "Could not send the magic link email" }, 502);
  }

  return jsonResponse({ ok: true });
}

/// Sends the magic-link email via the Resend HTTP API. With the default
/// onboarding@resend.dev sender, Resend only delivers to the address the API key's
/// account signed up with — fine for single-user/testing without a domain. Add a
/// verified domain in Resend later to send to anyone.
async function sendMagicLinkEmail(
  email: string,
  link: string,
  env: Env
): Promise<void> {
  const subject = "Your Macky sign-in link";
  const text = [
    "Sign in to Macky",
    "",
    "Click the link below to finish signing in. It expires in 15 minutes and can be used once.",
    "",
    link,
    "",
    "If you didn't request this, you can safely ignore this email.",
  ].join("\n");

  const html = `<!DOCTYPE html>
<html>
  <body style="margin:0;padding:0;background:#0b0b0c;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#0b0b0c;padding:40px 0;">
      <tr>
        <td align="center">
          <table role="presentation" width="420" cellpadding="0" cellspacing="0" style="background:#151517;border-radius:16px;padding:32px;">
            <tr><td style="color:#ffffff;font-size:20px;font-weight:700;padding-bottom:8px;">Sign in to Macky</td></tr>
            <tr><td style="color:#a1a1aa;font-size:14px;line-height:20px;padding-bottom:24px;">Click the button below to finish signing in. This link expires in 15 minutes and can only be used once.</td></tr>
            <tr>
              <td style="padding-bottom:24px;">
                <a href="${link}" style="display:inline-block;background:#6d5efc;color:#ffffff;text-decoration:none;font-size:14px;font-weight:600;padding:12px 24px;border-radius:10px;">Sign in to Macky</a>
              </td>
            </tr>
            <tr><td style="color:#71717a;font-size:12px;line-height:18px;">If the button doesn't work, copy and paste this link:<br><a href="${link}" style="color:#8b7dff;word-break:break-all;">${link}</a></td></tr>
            <tr><td style="color:#52525b;font-size:12px;padding-top:24px;">If you didn't request this, you can safely ignore this email.</td></tr>
          </table>
        </td>
      </tr>
    </table>
  </body>
</html>`;

  if (!env.RESEND_API_KEY) {
    throw new Error("RESEND_API_KEY is not configured");
  }

  const from = env.MAGIC_LINK_FROM.includes("<")
    ? env.MAGIC_LINK_FROM
    : `Macky <${env.MAGIC_LINK_FROM}>`;

  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.RESEND_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ from, to: [email], subject, html, text }),
  });

  if (!response.ok) {
    const body = await response.text().catch(() => "");
    throw new Error(`Resend send failed ${response.status}: ${body}`);
  }
}

/// GET /auth/open?token=… — minimal HTML bridge that hands the browser off to the
/// app via the Macky:// scheme. Custom schemes can't be a plain 3xx redirect target
/// in every browser, so we trigger it from the page and also offer a manual button.
function handleAuthOpen(url: URL): Response {
  const token = url.searchParams.get("token") ?? "";
  // Only allow the UUID token shape through into the deep link to avoid reflecting
  // arbitrary content into the Macky:// URL.
  const safeToken = /^[A-Za-z0-9-]+$/.test(token) ? token : "";
  if (!safeToken) {
    return new Response("Invalid or missing token", { status: 400 });
  }

  const deepLink = `Macky://auth?token=${safeToken}`;
  const html = `<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Opening Macky…</title>
    <meta http-equiv="refresh" content="0;url=${deepLink}">
    <style>
      body{margin:0;background:#0b0b0c;color:#fff;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;display:flex;min-height:100vh;align-items:center;justify-content:center;}
      .card{text-align:center;padding:32px;}
      a.btn{display:inline-block;margin-top:16px;background:#6d5efc;color:#fff;text-decoration:none;font-weight:600;padding:12px 24px;border-radius:10px;}
      p{color:#a1a1aa;font-size:14px;}
    </style>
  </head>
  <body>
    <div class="card">
      <h2>Opening Macky…</h2>
      <p>If the app didn't open automatically, click below.</p>
      <a class="btn" href="${deepLink}">Open Macky</a>
    </div>
    <script>window.location.href = ${JSON.stringify(deepLink)};</script>
  </body>
</html>`;

  return new Response(html, {
    headers: { "Content-Type": "text/html; charset=utf-8" },
  });
}

/// GET /auth/connected?toolkit=… — the `callback_url` Composio's hosted connect page
/// redirects the browser to once a connector finishes linking. Bounces into the app via
/// the Macky:// scheme (same pattern as `handleAuthOpen`) so the connectors grid can
/// refresh immediately instead of waiting for the user to switch back manually.
function handleAuthConnected(url: URL): Response {
  const rawToolkit = url.searchParams.get("toolkit") ?? "";
  // Only allow a plain slug-shaped value through into the deep link.
  const toolkit = /^[a-z0-9_-]+$/i.test(rawToolkit) ? rawToolkit.toLowerCase() : "";

  const deepLink = toolkit ? `Macky://connected?toolkit=${toolkit}` : "Macky://connected";
  const html = `<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Connected — returning to Macky…</title>
    <meta http-equiv="refresh" content="0;url=${deepLink}">
    <style>
      body{margin:0;background:#0b0b0c;color:#fff;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;display:flex;min-height:100vh;align-items:center;justify-content:center;}
      .card{text-align:center;padding:32px;}
      a.btn{display:inline-block;margin-top:16px;background:#6d5efc;color:#fff;text-decoration:none;font-weight:600;padding:12px 24px;border-radius:10px;}
      p{color:#a1a1aa;font-size:14px;}
    </style>
  </head>
  <body>
    <div class="card">
      <h2>Connected — returning to Macky…</h2>
      <p>If the app didn't come back to the front automatically, click below.</p>
      <a class="btn" href="${deepLink}">Open Macky</a>
    </div>
    <script>window.location.href = ${JSON.stringify(deepLink)};</script>
  </body>
</html>`;

  return new Response(html, {
    headers: { "Content-Type": "text/html; charset=utf-8" },
  });
}

/// POST /auth/verify — validates a magic-link token, provisions the Composio user for
/// the email, and returns `{ sessionToken, composioUserId }`. Tokens are single-use:
/// consumed on the first successful verify. The returned session's `composioUserId` is
/// the email — stable across reinstalls/devices — and replaces whatever anonymous
/// session (see `handleAnonymousAuth`) the app was previously using; toolkits connected
/// under the old anonymous identity are not migrated.
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

  // Provisions the Composio user (best-effort — auth still succeeds even if Composio is
  // briefly unavailable) and mints the session the app will present as a bearer token
  // on every subsequent Composio call.
  const { sessionToken, composioUserId } = await createSession(email, "email", env, email);
  return jsonResponse({ sessionToken, composioUserId });
}

/// POST /auth/anonymous — mints a fresh, no-login Composio identity + session. Called by
/// the app on first run (or whenever it has no stored session), so connectors work
/// immediately without requiring the user to complete email auth first. Returns the same
/// `{ sessionToken, composioUserId }` shape as `/auth/verify`.
async function handleAnonymousAuth(env: Env): Promise<Response> {
  const composioUserId = `anon-${crypto.randomUUID()}`;
  const { sessionToken } = await createSession(composioUserId, "anonymous", env);
  return jsonResponse({ sessionToken, composioUserId });
}

/// Ensures a Composio user/entity exists for `composioUserId` by opening a Tool Router
/// session with that `user_id` (Composio auto-provisions the entity on first use).
/// Failures are logged but not surfaced, so a Composio hiccup never blocks login.
async function provisionComposioUser(composioUserId: string, env: Env): Promise<void> {
  try {
    const response = await fetch(
      "https://backend.composio.dev/api/v3.1/tool_router/session",
      {
        method: "POST",
        headers: {
          "x-api-key": env.COMPOSIO_API_KEY,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ user_id: composioUserId }),
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
    "https://abhilashreddymand-0825-resource.services.ai.azure.com/openai/v1/realtime?model=gpt-realtime-2.1";

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
