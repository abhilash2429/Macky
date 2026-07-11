export interface Env {
  AZURE_OPENAI_API_KEY: string;
  COMPOSIO_API_KEY: string;
  // Pending magic-link tokens: token -> email, 15-minute TTL.
  AUTH_TOKENS: KVNamespace;
  // Long-lived Composio sessions: sessionToken -> ComposioSession (JSON). Created by
  // /auth/anonymous (first-run, no login) and /auth/verify (email login). No TTL —
  // a session lives as long as the app's Keychain entry does.
  SESSIONS: KVNamespace;
  // Durable session state for typed non-realtime events. The realtime socket remains
  // byte-forwarded; this object is the foundation for reconnect-safe side channels.
  SESSION_OBJECTS: DurableObjectNamespace;
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
  // Azure deployment name for the primary visual-guidance model that generates
  // coordinates from a screenshot. Defaults to "gpt-5.6-sol" when unset. Runs on the same
  // Azure resource / api-key as the realtime endpoint.
  CANVAS_VISION_MODEL: string;
}

const DEFAULT_SESSION_ID = "default";

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

interface TypedSessionEvent {
  version: 1;
  type: string;
  messageId?: string;
  sessionId?: string;
  taskId?: string;
  timestamp?: string;
  payload?: unknown;
}

interface SessionSnapshot {
  sessionId: string;
  currentRealtimeSessionId?: string;
  recentEvents: TypedSessionEvent[];
  updatedAt: string;
}

export class MackySessionObject implements DurableObject {
  constructor(private state: DurableObjectState) {}

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const sessionId = url.searchParams.get("sessionId") || DEFAULT_SESSION_ID;

    if (request.method === "GET" && url.pathname === "/state") {
      return jsonResponse(await this.snapshot(sessionId));
    }

    if (request.method === "POST" && url.pathname === "/event") {
      const event = await readTypedSessionEvent(request, sessionId);
      if (!event) return jsonResponse({ error: "invalid event" }, 400);
      const snapshot = await this.snapshot(sessionId);
      snapshot.recentEvents.push(event);
      snapshot.recentEvents = snapshot.recentEvents.slice(-50);
      snapshot.updatedAt = event.timestamp ?? new Date().toISOString();
      await this.state.storage.put(sessionId, snapshot);
      return jsonResponse({ ok: true });
    }

    return new Response("Not found", { status: 404 });
  }

  private async snapshot(sessionId: string): Promise<SessionSnapshot> {
    const existing = await this.state.storage.get<SessionSnapshot>(sessionId);
    return existing ?? {
      sessionId,
      recentEvents: [],
      updatedAt: new Date().toISOString(),
    };
  }
}

async function readTypedSessionEvent(request: Request, sessionId: string): Promise<TypedSessionEvent | null> {
  const body = (await request.json().catch(() => null)) as Partial<TypedSessionEvent> | null;
  if (!body || body.version !== 1 || typeof body.type !== "string" || !body.type) {
    return null;
  }
  return {
    version: 1,
    type: body.type,
    messageId: typeof body.messageId === "string" ? body.messageId : crypto.randomUUID(),
    sessionId: typeof body.sessionId === "string" ? body.sessionId : sessionId,
    taskId: typeof body.taskId === "string" ? body.taskId : undefined,
    timestamp: typeof body.timestamp === "string" ? body.timestamp : new Date().toISOString(),
    payload: body.payload,
  };
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

    if (url.pathname === "/canvas-vision" && request.method === "POST") {
      return handleCanvasVision(request, env);
    }

    if (url.pathname === "/session/state" && request.method === "GET") {
      return forwardSessionObject(request, url, env, "/state");
    }

    if (url.pathname === "/session/event" && request.method === "POST") {
      return forwardSessionObject(request, url, env, "/event");
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

/// Generates visual-guidance canvas commands from a screenshot. The Swift app captures
/// the screen locally and POSTs the JPEG here when the realtime model explicitly asks for
/// deeper coordinate help; we run a vision Responses API call on the same Azure resource as
/// the realtime endpoint and return a VisualGuidanceSequence as `canvas_payload`. Keeping
/// this off the realtime path preserves the pure-byte-proxy invariant for `/realtime`, while
/// the realtime model remains the voice brain that decides when visual guidance is needed.
///
/// Success: { canvas_payload: "<sequence JSON string>", error: null }
/// Failure: { canvas_payload: null, error: "<reason>" }. Request/auth failures use their
///          corresponding HTTP status; upstream model/validation failures remain structured.
async function handleCanvasVision(request: Request, env: Env): Promise<Response> {
  const session = await resolveSession(request, env);
  if (!session) {
    return jsonResponse({ canvas_payload: null, error: "missing or invalid session" }, 401);
  }

  const requestID = crypto.randomUUID();
  let jpegBase64 = "";
  let transcript = "";
  let logicalWidth = 0;
  let logicalHeight = 0;
  try {
    const body = (await request.json()) as {
      jpegBase64?: unknown;
      transcript?: unknown;
      logicalWidth?: unknown;
      logicalHeight?: unknown;
    };
    jpegBase64 = typeof body.jpegBase64 === "string" ? body.jpegBase64 : "";
    transcript = typeof body.transcript === "string" ? body.transcript.trim() : "";
    logicalWidth = typeof body.logicalWidth === "number" ? Math.round(body.logicalWidth) : 0;
    logicalHeight = typeof body.logicalHeight === "number" ? Math.round(body.logicalHeight) : 0;
  } catch {
    return jsonResponse({ canvas_payload: null, error: "invalid JSON body", request_id: requestID }, 400);
  }
  if (!jpegBase64) {
    return jsonResponse({ canvas_payload: null, error: "missing jpegBase64", request_id: requestID }, 400);
  }
  // Base64 is roughly 4/3 the source size. Keep screenshots below a conservative
  // per-request application limit so an accidental capture cannot consume excessive memory.
  if (jpegBase64.length > 11_200_000) {
    return jsonResponse({ canvas_payload: null, error: "screenshot is too large", request_id: requestID }, 413);
  }
  if (transcript.length > 4_000) {
    return jsonResponse({ canvas_payload: null, error: "guidance request is too long", request_id: requestID }, 400);
  }
  if (logicalWidth <= 0 || logicalHeight <= 0 || logicalWidth > 16_384 || logicalHeight > 16_384) {
    return jsonResponse({ canvas_payload: null, error: "missing or invalid source dimensions", request_id: requestID }, 400);
  }
  console.log("CanvasVisionDiagnostics request", {
    requestID,
    logicalWidth,
    logicalHeight,
    jpegBase64Length: jpegBase64.length,
    transcriptLength: transcript.length,
  });

  const deployment = env.CANVAS_VISION_MODEL || "gpt-5.6-sol";
  const azureUrl = "https://abhilashreddymand-0825-resource.services.ai.azure.com/openai/v1/responses";

  const systemPrompt = canvasVisionSystemPrompt(logicalWidth, logicalHeight);
  const userText = transcript || "Teach the user what to do on the visible screen.";
  const safetyIdentifier = await safetyIdentifierForSession(session);

  const buildVisionRequestBody = (imageDetail: "original" | "high") => JSON.stringify({
    model: deployment,
    store: false,
    safety_identifier: safetyIdentifier,
    instructions: systemPrompt,
    input: [
      {
        role: "user",
        content: [
          { type: "input_text", text: userText },
          {
            type: "input_image",
            image_url: `data:image/jpeg;base64,${jpegBase64}`,
            detail: imageDetail,
          },
        ],
      },
    ],
    text: {
      format: {
        type: "json_schema",
        name: "visual_guidance_sequence",
        strict: true,
        schema: canvasVisionOutputSchema(),
      },
    },
    reasoning: { effort: "high" },
    max_output_tokens: 4_000,
  });

  const fetchVisionResponse = (imageDetail: "original" | "high") => fetch(azureUrl, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "api-key": env.AZURE_OPENAI_API_KEY,
    },
    body: buildVisionRequestBody(imageDetail),
  });

  let azureResponse: Response;
  let usedImageDetail: "original" | "high" = "original";
  try {
    azureResponse = await fetchVisionResponse(usedImageDetail);
  } catch (err) {
    console.error("Canvas vision fetch failed", requestID, err);
    return jsonResponse({ canvas_payload: null, error: "vision request failed", request_id: requestID });
  }

  if (!azureResponse.ok && azureResponse.status === 400) {
    const originalDetailError = await azureResponse.text().catch(() => "");
    if (/\bdetail\b|\boriginal\b/i.test(originalDetailError)) {
      console.warn("Canvas vision original detail rejected; retrying with high", requestID);
      usedImageDetail = "high";
      try {
        azureResponse = await fetchVisionResponse(usedImageDetail);
      } catch (err) {
        console.error("Canvas vision fallback fetch failed", requestID, err);
        return jsonResponse({ canvas_payload: null, error: "vision request failed", request_id: requestID });
      }
    } else {
      console.error("Canvas vision request rejected", requestID, originalDetailError);
      return jsonResponse({ canvas_payload: null, error: "vision request was rejected", request_id: requestID });
    }
  }

  if (!azureResponse.ok) {
    const detail = await azureResponse.text().catch(() => "");
    console.error("Canvas vision non-OK", requestID, azureResponse.status, detail);
    return jsonResponse({
      canvas_payload: null,
      error: `vision model error (status ${azureResponse.status})`,
      request_id: requestID,
    });
  }

  let content = "";
  let refusal = "";
  try {
    const data = (await azureResponse.json()) as {
      output_text?: unknown;
      output?: Array<{ content?: Array<{ type?: string; text?: unknown; refusal?: unknown }> }>;
    };
    if (typeof data.output_text === "string") {
      content = data.output_text;
    } else {
      const outputParts = (data.output ?? []).flatMap((item) => item.content ?? []);
      content = outputParts
        .filter((part) => part.type === "output_text" && typeof part.text === "string")
        .map((part) => part.text as string)
        .join("\n");
      refusal = outputParts
        .filter((part) => part.type === "refusal" && typeof part.refusal === "string")
        .map((part) => part.refusal as string)
        .join(" ");
    }
  } catch (err) {
    console.error("Canvas vision response parse failed", requestID, err);
    return jsonResponse({ canvas_payload: null, error: "vision response unreadable", request_id: requestID });
  }
  if (refusal) {
    console.warn("Canvas vision refused request", requestID);
    return jsonResponse({ canvas_payload: null, error: "vision model refused the request", request_id: requestID });
  }
  if (!content) {
    return jsonResponse({ canvas_payload: null, error: "vision returned empty content", request_id: requestID });
  }

  let sequence: unknown;
  try {
    sequence = JSON.parse(content.trim());
  } catch (err) {
    console.error("Canvas vision JSON.parse failed", requestID, err);
    return jsonResponse({ canvas_payload: null, error: "vision returned invalid JSON", request_id: requestID });
  }

  const validationError = validateCanvasVisionSequence(sequence, logicalWidth, logicalHeight);
  console.log("CanvasVisionDiagnostics response", {
    requestID,
    logicalWidth,
    logicalHeight,
    imageDetail: usedImageDetail,
    sourceWidth: (sequence as { source_width?: unknown } | null)?.source_width,
    sourceHeight: (sequence as { source_height?: unknown } | null)?.source_height,
    steps: Array.isArray((sequence as { steps?: unknown } | null)?.steps) ? ((sequence as { steps?: unknown[] }).steps?.length ?? 0) : -1,
    validationError,
  });
  if (validationError) {
    return jsonResponse({ canvas_payload: null, error: validationError, request_id: requestID });
  }

  const guidanceSummary = typeof (sequence as { summary?: unknown }).summary === "string"
    ? (sequence as { summary: string }).summary
    : null;
  return jsonResponse({
    canvas_payload: JSON.stringify(sequence),
    guidance_summary: guidanceSummary,
    image_detail: usedImageDetail,
    request_id: requestID,
    error: null,
  });
}

/// Strict Responses API schema. Nullable fields are required so the model cannot silently
/// omit shape-critical keys; Swift decodes JSON null into its existing optional properties.
function canvasVisionOutputSchema(): Record<string, unknown> {
  const nullableNumber = { type: ["number", "null"] };
  const pointSchema = {
    type: "object",
    additionalProperties: false,
    required: ["x", "y"],
    properties: {
      x: { type: "number" },
      y: { type: "number" },
    },
  };
  const animationSchema = {
    anyOf: [
      { type: "null" },
      {
        type: "object",
        additionalProperties: false,
        required: ["type", "duration_ms", "delay_ms", "repeat", "easing"],
        properties: {
          type: { type: "string", enum: ["none", "fade_in", "scale_in", "pulse", "draw", "dash_flow"] },
          duration_ms: { type: ["integer", "null"], minimum: 100, maximum: 2_500 },
          delay_ms: { type: ["integer", "null"], minimum: 0, maximum: 1_500 },
          repeat: { type: ["integer", "null"], minimum: 1, maximum: 5 },
          easing: {
            type: ["string", "null"],
            enum: ["linear", "ease_in", "ease_out", "ease_in_out", null],
          },
        },
      },
    ],
  };
  const commandSchema = {
    type: "object",
    additionalProperties: false,
    required: ["type", "x", "y", "width", "height", "to_x", "to_y", "points", "text", "animation"],
    properties: {
      type: {
        type: "string",
        enum: ["highlight", "arrow", "label", "polygon", "circle", "ring", "spotlight", "line", "brace"],
      },
      x: nullableNumber,
      y: nullableNumber,
      width: nullableNumber,
      height: nullableNumber,
      to_x: nullableNumber,
      to_y: nullableNumber,
      points: {
        anyOf: [
          { type: "null" },
          { type: "array", minItems: 3, maxItems: 16, items: pointSchema },
        ],
      },
      text: { type: ["string", "null"], minLength: 1, maxLength: 120 },
      animation: animationSchema,
    },
  };
  const cursorSchema = {
    anyOf: [
      { type: "null" },
      {
        type: "object",
        additionalProperties: false,
        required: ["type", "x", "y", "duration_ms", "label", "label_placement"],
        properties: {
          type: { type: "string", enum: ["move"] },
          x: { type: "number" },
          y: { type: "number" },
          duration_ms: { type: ["integer", "null"], minimum: 100, maximum: 2_000 },
          label: { type: ["string", "null"], minLength: 1, maxLength: 80 },
          label_placement: {
            type: ["string", "null"],
            enum: ["above", "below", "left", "right", "above_right", "below_right", "above_left", "below_left", null],
          },
        },
      },
    ],
  };

  return {
    type: "object",
    additionalProperties: false,
    required: ["summary", "title", "source_width", "source_height", "steps"],
    properties: {
      summary: { type: "string", minLength: 1, maxLength: 240 },
      title: { type: ["string", "null"], minLength: 1, maxLength: 120 },
      source_width: { type: "number" },
      source_height: { type: "number" },
      steps: {
        type: "array",
        minItems: 1,
        maxItems: 12,
        items: {
          type: "object",
          additionalProperties: false,
          required: ["narration_cue", "duration_ms", "clear_before_next", "canvas", "cursor"],
          properties: {
            narration_cue: { type: ["string", "null"], minLength: 1, maxLength: 240 },
            duration_ms: { type: "integer", minimum: 4_000, maximum: 20_000 },
            clear_before_next: { type: "boolean" },
            canvas: { type: "array", maxItems: 8, items: commandSchema },
            cursor: cursorSchema,
          },
        },
      },
    },
  };
}

export function validateCanvasVisionSequence(sequence: unknown, logicalWidth: number, logicalHeight: number): string | null {
  if (!sequence || typeof sequence !== "object") return "vision returned invalid sequence";
  const candidate = sequence as { summary?: unknown; title?: unknown; source_width?: unknown; source_height?: unknown; steps?: unknown };
  if (typeof candidate.summary !== "string" || candidate.summary.trim() === "" || candidate.summary.length > 240) {
    return "vision returned invalid summary";
  }
  if (candidate.title !== null && candidate.title !== undefined
    && (typeof candidate.title !== "string" || candidate.title.trim() === "" || candidate.title.length > 120)) {
    return "vision returned invalid title";
  }
  if (candidate.source_width !== logicalWidth || candidate.source_height !== logicalHeight) {
    return "vision returned mismatched source dimensions";
  }
  if (!Array.isArray(candidate.steps) || candidate.steps.length === 0) {
    return "vision returned no steps";
  }
  if (candidate.steps.length > 12) {
    return "vision returned too many steps";
  }
  for (const [stepIndex, rawStep] of candidate.steps.entries()) {
    if (!rawStep || typeof rawStep !== "object") return `vision returned invalid step ${stepIndex + 1}`;
    const step = rawStep as {
      narration_cue?: unknown;
      duration_ms?: unknown;
      clear_before_next?: unknown;
      canvas?: unknown;
      cursor?: unknown;
    };
    if (step.narration_cue !== null && step.narration_cue !== undefined
      && (typeof step.narration_cue !== "string" || step.narration_cue.trim() === "" || step.narration_cue.length > 240)) {
      return `vision returned invalid narration in step ${stepIndex + 1}`;
    }
    if (!Array.isArray(step.canvas)) return `vision returned invalid canvas in step ${stepIndex + 1}`;
    if (step.canvas.length > 8) return `vision returned too many canvas commands in step ${stepIndex + 1}`;
    if (!integerInRange(step.duration_ms, 4_000, 20_000)) return `vision returned invalid duration in step ${stepIndex + 1}`;
    if (typeof step.clear_before_next !== "boolean") return `vision returned invalid clear behavior in step ${stepIndex + 1}`;
    if (step.canvas.filter((command) => (command as { type?: unknown })?.type === "spotlight").length > 1) {
      return `vision returned multiple spotlights in step ${stepIndex + 1}`;
    }
    if (step.canvas.length === 0 && (step.cursor === null || step.cursor === undefined)) {
      return `vision returned empty step ${stepIndex + 1}`;
    }
    for (const [commandIndex, rawCommand] of step.canvas.entries()) {
      const error = validateCanvasVisionCommand(rawCommand, logicalWidth, logicalHeight, `step ${stepIndex + 1} command ${commandIndex + 1}`);
      if (error) return error;
    }
    if (step.cursor !== null && step.cursor !== undefined) {
      const cursor = step.cursor as { type?: unknown; x?: unknown; y?: unknown; duration_ms?: unknown; label?: unknown; label_placement?: unknown };
      if (cursor.type !== "move") return `vision returned unsupported cursor action in step ${stepIndex + 1}`;
      if (!inBounds(cursor.x, cursor.y, logicalWidth, logicalHeight)) return `vision returned cursor out of bounds in step ${stepIndex + 1}`;
      if (cursor.duration_ms !== null && cursor.duration_ms !== undefined && !integerInRange(cursor.duration_ms, 100, 2_000)) {
        return `vision returned invalid cursor duration in step ${stepIndex + 1}`;
      }
      if (cursor.label !== null && cursor.label !== undefined
        && (typeof cursor.label !== "string" || cursor.label.trim() === "" || cursor.label.length > 80)) {
        return `vision returned invalid cursor label in step ${stepIndex + 1}`;
      }
      if (cursor.label_placement !== null && cursor.label_placement !== undefined) {
        const allowedPlacements = new Set(["above", "below", "left", "right", "above_right", "below_right", "above_left", "below_left"]);
        if (typeof cursor.label_placement !== "string" || !allowedPlacements.has(cursor.label_placement)) return `vision returned invalid cursor label placement in step ${stepIndex + 1}`;
      }
    }
  }
  return null;
}

function validateCanvasVisionCommand(command: unknown, logicalWidth: number, logicalHeight: number, label: string): string | null {
  if (!command || typeof command !== "object") return `vision returned invalid ${label}`;
  const item = command as { type?: unknown; x?: unknown; y?: unknown; width?: unknown; height?: unknown; to_x?: unknown; to_y?: unknown; points?: unknown; text?: unknown; animation?: unknown };
  switch (item.type) {
    case "highlight":
    case "circle":
    case "ring":
    case "spotlight":
    case "brace":
      if (!rectInBounds(item.x, item.y, item.width, item.height, logicalWidth, logicalHeight)) return `vision returned out-of-bounds ${label}`;
      break;
    case "arrow":
    case "line":
      if (!inBounds(item.x, item.y, logicalWidth, logicalHeight) || !inBounds(item.to_x, item.to_y, logicalWidth, logicalHeight)) return `vision returned out-of-bounds ${label}`;
      break;
    case "label":
      if (!inBounds(item.x, item.y, logicalWidth, logicalHeight)) return `vision returned out-of-bounds ${label}`;
      if (typeof item.text !== "string" || item.text.trim() === "" || item.text.length > 120) return `vision returned invalid text for ${label}`;
      break;
    case "polygon":
      if (!Array.isArray(item.points) || item.points.length < 3 || item.points.length > 16) return `vision returned invalid polygon ${label}`;
      for (const point of item.points) {
        const p = point as { x?: unknown; y?: unknown };
        if (!inBounds(p.x, p.y, logicalWidth, logicalHeight)) return `vision returned out-of-bounds polygon ${label}`;
      }
      break;
    default:
      return `vision returned unsupported ${label}`;
  }
  const animationError = validateCanvasVisionAnimation(item.animation, label);
  if (animationError) return animationError;
  return null;
}

function validateCanvasVisionAnimation(animation: unknown, label: string): string | null {
  if (animation === null || animation === undefined) return null;
  if (typeof animation !== "object") return `vision returned invalid animation for ${label}`;
  const item = animation as { type?: unknown; duration_ms?: unknown; delay_ms?: unknown; repeat?: unknown; easing?: unknown };
  const allowedTypes = new Set(["none", "fade_in", "scale_in", "pulse", "draw", "dash_flow"]);
  if (typeof item.type !== "string" || !allowedTypes.has(item.type)) return `vision returned unsupported animation for ${label}`;
  if (item.duration_ms !== null && item.duration_ms !== undefined && !integerInRange(item.duration_ms, 100, 2_500)) return `vision returned invalid animation duration for ${label}`;
  if (item.delay_ms !== null && item.delay_ms !== undefined && !integerInRange(item.delay_ms, 0, 1_500)) return `vision returned invalid animation delay for ${label}`;
  if (item.repeat !== null && item.repeat !== undefined && !integerInRange(item.repeat, 1, 5)) return `vision returned invalid animation repeat for ${label}`;
  if (item.easing !== null && item.easing !== undefined) {
    const allowedEasing = new Set(["linear", "ease_in", "ease_out", "ease_in_out"]);
    if (typeof item.easing !== "string" || !allowedEasing.has(item.easing)) return `vision returned unsupported animation easing for ${label}`;
  }
  return null;
}

function integerInRange(value: unknown, min: number, max: number): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= min && value <= max;
}

function inBounds(x: unknown, y: unknown, logicalWidth: number, logicalHeight: number): boolean {
  return typeof x === "number" && Number.isFinite(x) && typeof y === "number" && Number.isFinite(y) && x >= 0 && y >= 0 && x <= logicalWidth && y <= logicalHeight;
}

function rectInBounds(x: unknown, y: unknown, width: unknown, height: unknown, logicalWidth: number, logicalHeight: number): boolean {
  return typeof x === "number" && Number.isFinite(x) && typeof y === "number" && Number.isFinite(y) && typeof width === "number" && Number.isFinite(width) && typeof height === "number" && Number.isFinite(height) && width > 0 && height > 0 && x >= 0 && y >= 0 && x + width <= logicalWidth && y + height <= logicalHeight;
}

/// The strict output schema owns field shape. The prompt owns visual judgment and the
/// screenshot-coordinate contract that determines whether drawings land on real controls.
function canvasVisionSystemPrompt(logicalWidth: number, logicalHeight: number): string {
  return [
    "You are Macky's visual teacher. Inspect the macOS screenshot and create a short overlay that visibly teaches the requested action.",
    `The screenshot coordinate space is exactly ${logicalWidth} by ${logicalHeight} IMAGE PIXELS with a TOP-LEFT origin.`,
    `Every x coordinate must be in 0..${logicalWidth}; every y coordinate must be in 0..${logicalHeight}.`,
    `Set source_width=${logicalWidth} and source_height=${logicalHeight}.`,
    "Locate controls from their actual visible boundaries. Do not estimate from generic app layouts or invent hidden controls.",
    "If the requested target is not visibly identifiable, return the safest nearby visible teaching step instead of fabricating a coordinate.",
    "For an arrow, (x,y) is the TAIL where the arrow starts, and (to_x,to_y) is the HEAD/TIP pointing at the target UI element.",
    "For a highlight, (x,y) is the top-left corner and width/height tightly bound the visible target.",
    "Use at most one spotlight per step. Keep it behind all arrows, labels, rings, and highlights.",
    "For small buttons, icons, menu items, tabs, and compact controls, prefer a cursor move with a 1-5 word label.",
    "Visual-guidance cursor actions only point; never emit clicks. Macky's separate cursor-control tool owns clicking and dragging.",
    "Use one teaching idea per step, usually 1-4 steps total. Keep labels concise and narration natural.",
    "Use draw for arrows/lines, pulse for a target, and fade_in or scale_in for simple emphasis. Avoid decorative animation.",
    "duration_ms is the total time for the step, including cursor movement.",
  ].join("\n");
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

function forwardSessionObject(
  request: Request,
  url: URL,
  env: Env,
  pathname: "/state" | "/event"
): Response | Promise<Response> {
  const sessionId = url.searchParams.get("sessionId") || DEFAULT_SESSION_ID;
  const id = env.SESSION_OBJECTS.idFromName(sessionId);
  const stub = env.SESSION_OBJECTS.get(id);
  const target = new URL(request.url);
  target.pathname = pathname;
  target.searchParams.set("sessionId", sessionId);
  return stub.fetch(new Request(target.toString(), request));
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
