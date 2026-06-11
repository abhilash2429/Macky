export interface Env {
  AZURE_OPENAI_API_KEY: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/realtime") {
      return handleRealtimeProxy(request, env);
    }

    return new Response("Not found", { status: 404 });
  },
};

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