export interface Env {
  AZURE_OPENAI_API_KEY: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === '/realtime') {
      return handleRealtimeProxy(request, env);
    }

    return new Response('Not found', { status: 404 });
  },
};

async function handleRealtimeProxy(request: Request, env: Env): Promise<Response> {
  const upgradeHeader = request.headers.get('Upgrade');
  if (!upgradeHeader || upgradeHeader !== 'websocket') {
    return new Response('Expected WebSocket upgrade', { status: 426 });
  }

  const azureEndpoint =
    'wss://auren-resource.services.ai.azure.com/openai/v1/realtime?model=gpt-realtime-2';

  const azureResponse = await fetch(azureEndpoint, {
    headers: {
      'api-key': env.AZURE_OPENAI_API_KEY,
      Upgrade: 'websocket',
      Connection: 'Upgrade',
    },
  });

  const azureSocket = (azureResponse as any).webSocket as (WebSocket & { accept(): void }) | undefined;
  if (!azureSocket) {
    return new Response('Failed to connect to Azure upstream', { status: 502 });
  }

  azureSocket.accept();

  const { 0: clientSocket, 1: serverSocket } =
    new (globalThis as any).WebSocketPair();
  serverSocket.accept();

  // client → Azure
  serverSocket.addEventListener('message', (event: MessageEvent) => {
    azureSocket.send(event.data);
  });

  // Azure → client
  azureSocket.addEventListener('message', (event: MessageEvent) => {
    serverSocket.send(event.data);
  });

  serverSocket.addEventListener('close', (event: CloseEvent) => {
    try { azureSocket.close(event.code, event.reason); } catch {}
  });

  azureSocket.addEventListener('close', (event: CloseEvent) => {
    try { serverSocket.close(event.code, event.reason); } catch {}
  });

  serverSocket.addEventListener('error', () => {
    try { azureSocket.close(); } catch {}
  });

  azureSocket.addEventListener('error', () => {
    try { serverSocket.close(); } catch {}
  });

  return new Response(null, {
    status: 101,
    webSocket: clientSocket,
  } as any);
}