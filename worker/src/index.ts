export interface Env {
  AZURE_OPENAI_API_KEY: string;
  COMPOSIO_API_KEY: string;
  // Pending magic-link tokens: token -> email, 15-minute TTL.
  AUTH_TOKENS: KVNamespace;
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
  // Azure deployment name for the canvas vision model that generates visual-guidance
  // coordinates from a screenshot. Defaults to "gpt-5.5" when unset. Runs on the same
  // Azure resource / api-key as the realtime endpoint.
  CANVAS_VISION_MODEL: string;
}

/// Fixed Composio user for now. M14 (real per-user auth) swaps this one line.
const COMPOSIO_USER_ID = "speed-test-user";
const DEFAULT_SESSION_ID = "default";

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
      return handleComposioConfig(env);
    }

    if (url.pathname === "/composio-connect") {
      return handleComposioConnect(request, url, env);
    }

    if (url.pathname === "/composio-connections") {
      return handleComposioConnections(env);
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

    // Clickable https link from the email; bounces the browser into the app via
    // the Macky:// custom scheme. Custom-scheme links aren't clickable in Gmail,
    // so the email always points here instead.
    if (url.pathname === "/auth/open" && request.method === "GET") {
      return handleAuthOpen(url);
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

/// Initiates a Composio connection for a toolkit and returns the OAuth redirect
/// URL directly, so the app can open it without routing through the realtime voice
/// model (which would narrate filler). Two steps, both Composio-managed:
///   1. Look up an auth config for the toolkit slug.
///   2. Create a hosted connection `link` for COMPOSIO_USER_ID → redirect URL.
///
/// Body/query: `toolkit` (slug, e.g. "spotify"). Returns `{ toolkit, redirect_url }`.
async function handleComposioConnect(
  request: Request,
  url: URL,
  env: Env
): Promise<Response> {
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

    // 2. Create a hosted connection link → OAuth redirect URL for the user.
    const linkResponse = await fetch(
      "https://backend.composio.dev/api/v3/connected_accounts/link",
      {
        method: "POST",
        headers,
        body: JSON.stringify({
          user_id: COMPOSIO_USER_ID,
          auth_config_id: authConfigId,
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
/// prompt. Returns `{ connected: ["gmail", ...] }` (lowercased toolkit slugs).
async function handleComposioConnections(env: Env): Promise<Response> {
  try {
    const response = await fetch(
      `https://backend.composio.dev/api/v3/connected_accounts?user_ids=${encodeURIComponent(
        COMPOSIO_USER_ID
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

/// Executes a single Composio tool for COMPOSIO_USER_ID via the REST execute
/// endpoint and returns the parsed `{ successful, data, error }` envelope. This is
/// the *direct* path (no MCP tool-router discovery), so it's one hop with no voice
/// model in the loop — the whole point of the fast Spotify route below.
async function composioExecute(
  env: Env,
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
      body: JSON.stringify({ user_id: COMPOSIO_USER_ID, arguments: args }),
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
      const search = await composioExecute(env, "SPOTIFY_SEARCH_FOR_ITEM", {
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
      const transfer = await composioExecute(env, "SPOTIFY_TRANSFER_PLAYBACK", {
        device_ids: [idleDevice.id],
        play: true,
      });
      if (transfer.successful) {
        const retry = await startPlayback(env, uri, idleDevice.id);
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
  uri: string,
  deviceId?: string
): Promise<{ successful: boolean; data: any; error: unknown }> {
  const args: Record<string, unknown> = { uris: [uri] };
  if (deviceId) {
    args.device_id = deviceId;
  }
  return composioExecute(env, "SPOTIFY_START_RESUME_PLAYBACK", args);
}

/// Generates visual-guidance canvas commands from a screenshot. The Swift app captures
/// the screen locally and POSTs the JPEG here when the realtime model explicitly asks for
/// deeper coordinate help; we run a vision Responses API call on the same Azure resource as
/// the realtime endpoint and return a VisualGuidanceSequence as `canvas_payload`. Keeping
/// this off the realtime path preserves the pure-byte-proxy invariant for `/realtime`, while
/// the realtime model remains the brain that sees the screenshot, decides whether this helper
/// is needed, and chooses when to show the returned guide.
///
/// Success: { canvas_payload: "<sequence JSON string>", error: null }
/// Failure: { canvas_payload: null, error: "<reason>" } (HTTP 200 so the app reads the
///          structured null instead of throwing on a non-2xx status).
async function handleCanvasVision(request: Request, env: Env): Promise<Response> {
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
    transcript = typeof body.transcript === "string" ? body.transcript : "";
    logicalWidth = typeof body.logicalWidth === "number" ? Math.round(body.logicalWidth) : 0;
    logicalHeight = typeof body.logicalHeight === "number" ? Math.round(body.logicalHeight) : 0;
  } catch {
    return jsonResponse({ error: "invalid JSON body" }, 400);
  }
  if (!jpegBase64) {
    return jsonResponse({ error: "missing jpegBase64" }, 400);
  }
  if (logicalWidth <= 0 || logicalHeight <= 0) {
    return jsonResponse({ error: "missing or invalid logical dimensions" }, 400);
  }

  const deployment = env.CANVAS_VISION_MODEL || "gpt-5.5";
  const azureUrl = "https://auren-resource.services.ai.azure.com/openai/v1/responses";

  const systemPrompt = canvasVisionSystemPrompt(logicalWidth, logicalHeight);
  const userText =
    (transcript || "Help the user with what's currently on screen.") +
    `\n\nReturn the visual guide as JSON. Display logical dimensions: ${logicalWidth}x${logicalHeight}`;

  let azureResponse: Response;
  try {
    azureResponse = await fetch(azureUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "api-key": env.AZURE_OPENAI_API_KEY,
      },
      body: JSON.stringify({
        model: deployment,
        instructions: systemPrompt,
        input: [
          {
            role: "user",
            content: [
              { type: "input_text", text: userText },
              {
                type: "input_image",
                image_url: `data:image/jpeg;base64,${jpegBase64}`,
                detail: "high",
              },
            ],
          },
        ],
        text: { format: { type: "json_object" } },
        max_output_tokens: 2000,
      }),
    });
  } catch (err) {
    console.error("Canvas vision fetch failed", err);
    return jsonResponse({ canvas_payload: null, error: "vision request failed" });
  }

  if (!azureResponse.ok) {
    const detail = await azureResponse.text().catch(() => "");
    console.error("Canvas vision non-OK", azureResponse.status, detail);
    return jsonResponse({
      canvas_payload: null,
      error: `vision model error (status ${azureResponse.status})`,
    });
  }

  let content = "";
  try {
    const data = (await azureResponse.json()) as {
      output_text?: unknown;
      output?: Array<{ content?: Array<{ type?: string; text?: unknown }> }>;
    };
    if (typeof data.output_text === "string") {
      content = data.output_text;
    } else {
      content = (data.output ?? [])
        .flatMap((item) => item.content ?? [])
        .filter((part) => part.type === "output_text" && typeof part.text === "string")
        .map((part) => part.text as string)
        .join("\n");
    }
  } catch (err) {
    console.error("Canvas vision response parse failed", err);
    return jsonResponse({ canvas_payload: null, error: "vision response unreadable" });
  }
  if (!content) {
    return jsonResponse({ canvas_payload: null, error: "vision returned empty content" });
  }

  // Strip any accidental markdown fencing before parsing.
  const cleaned = content
    .trim()
    .replace(/^```(?:json)?\s*/i, "")
    .replace(/\s*```$/i, "")
    .trim();

  let sequence: unknown;
  try {
    sequence = JSON.parse(cleaned);
  } catch (err) {
    console.error("Canvas vision JSON.parse failed", err);
    return jsonResponse({ canvas_payload: null, error: "vision returned invalid JSON" });
  }

  const steps = (sequence as { steps?: unknown } | null)?.steps;
  if (!Array.isArray(steps) || steps.length === 0) {
    return jsonResponse({ canvas_payload: null, error: "vision returned no steps" });
  }

  return jsonResponse({ canvas_payload: JSON.stringify(sequence), error: null });
}

/// The system prompt for the canvas vision model. Inlines the VisualGuidanceSequence schema
/// (mirrors leanring-buddy/VisualGuidanceModels.swift) and states the coordinate contract:
/// logical points, top-left origin, and the arrow tail/head semantics (Bug 5).
function canvasVisionSystemPrompt(logicalWidth: number, logicalHeight: number): string {
  return [
    "You generate a visual teaching overlay for a macOS screenshot.",
    "Return ONLY a valid JSON object matching this schema — no markdown fencing, no prose:",
    "{",
    '  "title": string (optional),',
    `  "source_width": number (set to ${logicalWidth}),`,
    `  "source_height": number (set to ${logicalHeight}),`,
    '  "steps": [ {',
    '    "narration_cue": string (optional),',
    '    "duration_ms": integer (optional),',
    '    "clear_before_next": boolean (optional, default true),',
    '    "canvas": [ {',
    '      "type": "highlight" | "arrow" | "label" | "polygon",',
    '      "x": number, "y": number,',
    '      "width": number, "height": number,   // highlight rect size',
    '      "to_x": number, "to_y": number,       // arrow head/tip',
    '      "text": string,                        // label text',
    '      "points": [ { "x": number, "y": number } ]  // polygon (3-16 points)',
    "    } ],",
    '    "cursor": { "type": "move" | "click", "x": number, "y": number, "duration_ms": integer } (optional)',
    "  } ]",
    "}",
    "",
    `Coordinates are in LOGICAL SCREEN POINTS with a TOP-LEFT origin: x in 0..${logicalWidth}, y in 0..${logicalHeight}.`,
    "For an arrow, (x,y) is the TAIL where the arrow starts, and (to_x,to_y) is the HEAD/TIP pointing at the target UI element.",
    "For a highlight, (x,y) is the top-left corner and width/height size the box around the target.",
    `Always set source_width=${logicalWidth} and source_height=${logicalHeight}.`,
    "Keep the sequence short and clear. Point precisely at the real on-screen UI elements.",
  ].join("\n");
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
