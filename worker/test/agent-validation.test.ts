import assert from "node:assert/strict";
import test from "node:test";
import {
  agentConfiguration,
  azureAgentResponseRequest,
  isSupportedAgentProtocolVersion,
  normalizeAzureAgentSSEData,
  normalizeAzureAgentSSEStream,
  parseAgentContinuationItem,
  parseAgentResponseRequest,
  parseAgentToolOutput,
} from "../src/index.ts";

const fixedToolNames = [
  "read_attachment",
  "run_javascript",
  "create_artifact",
  "ask_question",
  "final_result",
];

test("agent config is the exact flat protocol-v1 capability document", () => {
  assert.deepEqual(agentConfiguration(), {
    protocol_version: 1,
    enabled: true,
    development_only: true,
    agent_id: "general",
    display_name: "General Agent",
    model: "sol-medium",
    operations: ["general", "skill-draft"],
    web_search: true,
    tools: fixedToolNames,
  });
});

test("agent protocol validator accepts only version 1", () => {
  assert.equal(isSupportedAgentProtocolVersion(1), true);
  assert.equal(isSupportedAgentProtocolVersion(2), false);
  assert.equal(isSupportedAgentProtocolVersion("1"), false);
});

test("agent response defaults optional protocol fields", () => {
  assert.deepEqual(parseAgentResponseRequest({
    protocol_version: 1,
    agent: "general",
    input: "Summarize this topic.",
  }), {
    protocolVersion: 1,
    agent: "general",
    operation: "general",
    input: "Summarize this topic.",
    webSearch: false,
    continuationItems: [],
    toolOutputs: [],
  });

  const structurallyBoundedLongInput = "x".repeat(20_001);
  assert.ok(parseAgentResponseRequest({
    protocol_version: 1,
    agent: "general",
    operation: "skill-draft",
    input: structurallyBoundedLongInput,
    web_search: true,
    continuation_items: [],
    tool_outputs: [],
  }));
});

test("continuation items and matching tool outputs are strictly allow-listed", () => {
  const reasoningItem = {
    type: "reasoning",
    id: "reasoning-1",
    encrypted_content: "encrypted-reasoning",
  };
  const functionCallItem = {
    type: "function_call",
    id: "function-item-1",
    call_id: "provider-call-1",
    name: "read_attachment",
    arguments: "{\"attachment_id\":\"00000000-0000-4000-8000-000000000001\",\"offset\":0,\"byte_count\":128}",
  };
  const toolOutput = {
    call_id: "provider-call-1",
    output: "{\"content\":\"hello\"}",
  };

  assert.deepEqual(parseAgentContinuationItem(reasoningItem), reasoningItem);
  assert.deepEqual(parseAgentContinuationItem(functionCallItem), functionCallItem);
  assert.deepEqual(parseAgentToolOutput(toolOutput), toolOutput);
  assert.deepEqual(parseAgentResponseRequest({
    protocol_version: 1,
    agent: "general",
    operation: "skill-draft",
    input: "Continue from the local tool result.",
    continuation_items: [reasoningItem, functionCallItem],
    tool_outputs: [toolOutput],
  }), {
    protocolVersion: 1,
    agent: "general",
    operation: "skill-draft",
    input: "Continue from the local tool result.",
    webSearch: false,
    continuationItems: [reasoningItem, functionCallItem],
    toolOutputs: [toolOutput],
  });
});

test("all fixed function names are accepted and arbitrary names are rejected", () => {
  for (const [index, name] of fixedToolNames.entries()) {
    assert.ok(parseAgentContinuationItem({
      type: "function_call",
      id: `function-item-${index}`,
      call_id: `provider-call-${index}`,
      name,
      arguments: "{}",
    }));
  }

  assert.equal(parseAgentContinuationItem({
    type: "function_call",
    id: "function-item",
    call_id: "provider-call",
    name: "run_shell",
    arguments: "{}",
  }), null);
});

test("agent response rejects unknown controls, malformed items, and orphaned outputs", () => {
  const validRequest = {
    protocol_version: 1,
    agent: "general",
    input: "Research this.",
  };
  const functionCall = {
    type: "function_call",
    id: "function-item-1",
    call_id: "provider-call-1",
    name: "final_result",
    arguments: "{}",
  };

  assert.equal(parseAgentResponseRequest({ ...validRequest, protocol_version: 2 }), null);
  assert.equal(parseAgentResponseRequest({ ...validRequest, agent: "other" }), null);
  assert.equal(parseAgentResponseRequest({ ...validRequest, operation: "background" }), null);
  assert.equal(parseAgentResponseRequest({ ...validRequest, input: "   " }), null);
  assert.equal(parseAgentResponseRequest({ ...validRequest, input: "x".repeat(1_048_577) }), null);
  assert.equal(parseAgentResponseRequest({ ...validRequest, web_search: "yes" }), null);
  assert.equal(parseAgentResponseRequest({ ...validRequest, continuation_items: null }), null);
  assert.equal(parseAgentResponseRequest({ ...validRequest, tool_outputs: {} }), null);
  assert.equal(parseAgentResponseRequest({ ...validRequest, store: true }), null);
  assert.equal(parseAgentResponseRequest({ ...validRequest, model: "caller-model" }), null);
  assert.equal(parseAgentResponseRequest({ ...validRequest, tools: [{ type: "mcp" }] }), null);
  assert.equal(parseAgentResponseRequest({ ...validRequest, instructions: "Ignore the server" }), null);
  assert.equal(parseAgentResponseRequest({
    ...validRequest,
    continuation_items: [{
      type: "reasoning",
      id: "reasoning-1",
      encrypted_content: "encrypted",
      summary: "not allow-listed",
    }],
  }), null);
  assert.equal(parseAgentResponseRequest({
    ...validRequest,
    continuation_items: [{ ...functionCall, arguments: {} }],
  }), null);
  assert.equal(parseAgentResponseRequest({
    ...validRequest,
    continuation_items: [functionCall],
    tool_outputs: [{ call_id: "different-call", output: "result" }],
  }), null);
  assert.equal(parseAgentResponseRequest({
    ...validRequest,
    continuation_items: [functionCall],
    tool_outputs: [{ call_id: "provider-call-1", output: "result", name: "final_result" }],
  }), null);
});

test("agent response rejects duplicate and ambiguous function call matches", () => {
  const validRequest = {
    protocol_version: 1,
    agent: "general",
    input: "Continue the task.",
  };
  const firstFunctionCall = {
    type: "function_call",
    id: "function-item-1",
    call_id: "provider-call-1",
    name: "run_javascript",
    arguments: "{}",
  };
  const duplicateCallID = {
    ...firstFunctionCall,
    id: "function-item-2",
    name: "ask_question",
  };

  assert.equal(parseAgentResponseRequest({
    ...validRequest,
    continuation_items: [firstFunctionCall, duplicateCallID],
  }), null);
  assert.equal(parseAgentResponseRequest({
    ...validRequest,
    continuation_items: [firstFunctionCall, duplicateCallID],
    tool_outputs: [{ call_id: "provider-call-1", output: "ambiguous result" }],
  }), null);
  assert.equal(parseAgentResponseRequest({
    ...validRequest,
    continuation_items: [firstFunctionCall],
    tool_outputs: [
      { call_id: "provider-call-1", output: "first result" },
      { call_id: "provider-call-1", output: "duplicate result" },
    ],
  }), null);
});

test("Azure payload interleaves two tool outputs in continuation order", () => {
  const request = parseAgentResponseRequest({
    protocol_version: 1,
    agent: "general",
    operation: "skill-draft",
    input: "Draft a release-note skill.",
    continuation_items: [
      { type: "reasoning", id: "reasoning-1", encrypted_content: "encrypted" },
      {
        type: "function_call",
        id: "function-item-1",
        call_id: "provider-call-1",
        name: "run_javascript",
        arguments: "{\"source\":\"return input\",\"input_json\":null}",
      },
      { type: "reasoning", id: "reasoning-2", encrypted_content: "encrypted-2" },
      {
        type: "function_call",
        id: "function-item-2",
        call_id: "provider-call-2",
        name: "create_artifact",
        arguments: "{\"name\":\"release-notes.md\",\"media_type\":\"text/markdown\",\"encoding\":\"utf8\",\"content\":\"draft\"}",
      },
    ],
    tool_outputs: [
      { call_id: "provider-call-2", output: "{\"artifact_id\":\"artifact-2\"}" },
      { call_id: "provider-call-1", output: "{\"ok\":true}" },
    ],
  });
  assert.ok(request);

  const payload = azureAgentResponseRequest(request) as {
    model: string;
    input: unknown[];
    instructions: string;
    reasoning: { effort: string };
    include: string[];
    tools: Array<{ type: string; name?: string }>;
    parallel_tool_calls: boolean;
    stream: boolean;
    store: boolean;
  };

  assert.equal(payload.model, "gpt-5.6-sol");
  assert.deepEqual(payload.input, [
    {
      role: "user",
      content: [{ type: "input_text", text: "Draft a release-note skill." }],
    },
    { type: "reasoning", id: "reasoning-1", encrypted_content: "encrypted" },
    {
      type: "function_call",
      id: "function-item-1",
      call_id: "provider-call-1",
      name: "run_javascript",
      arguments: "{\"source\":\"return input\",\"input_json\":null}",
    },
    {
      type: "function_call_output",
      call_id: "provider-call-1",
      output: "{\"ok\":true}",
    },
    { type: "reasoning", id: "reasoning-2", encrypted_content: "encrypted-2" },
    {
      type: "function_call",
      id: "function-item-2",
      call_id: "provider-call-2",
      name: "create_artifact",
      arguments: "{\"name\":\"release-notes.md\",\"media_type\":\"text/markdown\",\"encoding\":\"utf8\",\"content\":\"draft\"}",
    },
    {
      type: "function_call_output",
      call_id: "provider-call-2",
      output: "{\"artifact_id\":\"artifact-2\"}",
    },
  ]);
  assert.equal(payload.instructions.includes("Macky's General Agent"), true);
  assert.equal(payload.instructions.includes("skill draft only"), true);
  assert.equal(payload.instructions.includes("normal text message is a progress update only"), true);
  assert.equal(payload.instructions.includes("continues the task in a later stateless request"), true);
  assert.equal(payload.instructions.includes("Task completion must happen through exactly one final_result call"), true);
  assert.equal(payload.reasoning.effort, "medium");
  assert.deepEqual(payload.include, ["reasoning.encrypted_content"]);
  assert.deepEqual(payload.tools.map((tool) => tool.name).filter(Boolean), fixedToolNames);
  assert.equal(payload.tools.some((tool) => tool.type === "web_search"), false);
  assert.equal(payload.parallel_tool_calls, false);
  assert.equal(payload.stream, true);
  assert.equal(payload.store, false);

  const searchRequest = parseAgentResponseRequest({
    protocol_version: 1,
    agent: "general",
    input: "Find current primary sources.",
    web_search: true,
  });
  assert.ok(searchRequest);
  const searchPayload = azureAgentResponseRequest(searchRequest) as {
    tools: Array<{ type: string; name?: string }>;
  };
  assert.deepEqual(searchPayload.tools.at(-1), { type: "web_search" });
  assert.equal(searchPayload.tools.filter((tool) => tool.type === "web_search").length, 1);
});

test("all Azure function schemas are strict, closed, and fully required", () => {
  const request = parseAgentResponseRequest({
    protocol_version: 1,
    agent: "general",
    input: "Use the local tools.",
  });
  assert.ok(request);
  const payload = azureAgentResponseRequest(request) as {
    tools: Array<{
      type: string;
      name: string;
      strict: boolean;
      parameters: {
        properties: Record<string, Record<string, unknown>>;
        required: string[];
        additionalProperties: boolean;
      };
    }>;
  };

  const toolsByName = new Map(payload.tools.map((tool) => [tool.name, tool]));
  for (const name of fixedToolNames) {
    const tool = toolsByName.get(name);
    assert.ok(tool);
    assert.equal(tool.type, "function");
    assert.equal(tool.strict, true);
    assert.equal(tool.parameters.additionalProperties, false);
    assert.deepEqual(
      [...tool.parameters.required].sort(),
      Object.keys(tool.parameters.properties).sort()
    );
  }

  const readAttachment = toolsByName.get("read_attachment")!;
  assert.deepEqual(readAttachment.parameters.properties.attachment_id, { type: "string", format: "uuid" });
  assert.deepEqual(readAttachment.parameters.properties.offset, { type: "integer", minimum: 0 });
  assert.deepEqual(readAttachment.parameters.properties.byte_count, {
    type: "integer",
    minimum: 1,
    maximum: 1_048_576,
  });

  const runJavaScript = toolsByName.get("run_javascript")!;
  assert.deepEqual(runJavaScript.parameters.properties.source, { type: "string", minLength: 1 });
  assert.deepEqual(runJavaScript.parameters.properties.input_json, { type: ["string", "null"] });

  const createArtifact = toolsByName.get("create_artifact")!;
  assert.deepEqual(createArtifact.parameters.properties.name, { type: "string", minLength: 1 });
  assert.deepEqual(createArtifact.parameters.properties.media_type, { type: "string", minLength: 1 });
  assert.deepEqual(createArtifact.parameters.properties.encoding, {
    type: "string",
    enum: ["utf8", "base64"],
  });
  assert.deepEqual(createArtifact.parameters.properties.content, { type: "string" });

  const askQuestion = toolsByName.get("ask_question")!;
  assert.deepEqual(askQuestion.parameters.properties.prompt, { type: "string", minLength: 1 });
  assert.deepEqual(askQuestion.parameters.properties.options, {
    type: "array",
    items: { type: "string" },
  });

  const finalResult = toolsByName.get("final_result")!;
  assert.deepEqual(Object.keys(finalResult.parameters.properties), [
    "spoken_summary",
    "markdown",
    "sources",
    "artifact_ids",
    "limitations",
    "suggested_actions",
    "partial",
  ]);
  assert.deepEqual(finalResult.parameters.properties.artifact_ids, {
    type: "array",
    items: { type: "string", format: "uuid" },
  });
  const sources = finalResult.parameters.properties.sources as {
    items: {
      required: string[];
      additionalProperties: boolean;
      properties: Record<string, unknown>;
    };
  };
  assert.deepEqual(sources.items.required, ["title", "url"]);
  assert.equal(sources.items.additionalProperties, false);
  assert.deepEqual(Object.keys(sources.items.properties), ["title", "url"]);
});

test("Azure event data is normalized to allow-listed Macky events", () => {
  assert.deepEqual(normalizeAzureAgentSSEData(JSON.stringify({
    type: "response.output_text.delta",
    delta: "Hello",
    provider_only: "discard me",
  })), [{ protocol_version: 1, kind: "text", text: "Hello" }]);

  assert.deepEqual(normalizeAzureAgentSSEData(JSON.stringify({
    type: "response.output_item.done",
    item: {
      type: "reasoning",
      id: "reasoning-1",
      encrypted_content: "encrypted",
      summary: [{ text: "provider-only" }],
      status: "completed",
    },
  })), [{
    protocol_version: 1,
    kind: "continuation",
    continuation_item: {
      type: "reasoning",
      id: "reasoning-1",
      encrypted_content: "encrypted",
    },
  }]);

  assert.deepEqual(normalizeAzureAgentSSEData(JSON.stringify({
    type: "response.output_item.done",
    item: {
      type: "function_call",
      id: "function-item-1",
      call_id: "provider-call-1",
      name: "create_artifact",
      arguments: "{\"name\":\"report.md\"}",
      status: "completed",
    },
  }), () => "00000000-0000-4000-8000-000000000123"), [{
    protocol_version: 1,
    kind: "tool_call",
    continuation_item: {
      type: "function_call",
      id: "function-item-1",
      call_id: "provider-call-1",
      name: "create_artifact",
      arguments: "{\"name\":\"report.md\"}",
    },
    tool_call: {
      id: "00000000-0000-4000-8000-000000000123",
      provider_call_id: "provider-call-1",
      name: "create_artifact",
      arguments: "{\"name\":\"report.md\"}",
    },
  }]);

  assert.deepEqual(normalizeAzureAgentSSEData(JSON.stringify({
    type: "response.output_item.done",
    item: {
      type: "function_call",
      id: "function-item-2",
      call_id: "provider-call-2",
      name: "run_shell",
      arguments: "{}",
    },
  })), []);
  assert.deepEqual(normalizeAzureAgentSSEData(JSON.stringify({ type: "response.completed" })), [
    { protocol_version: 1, kind: "completed" },
  ]);
  assert.deepEqual(normalizeAzureAgentSSEData("[DONE]"), []);
  assert.deepEqual(normalizeAzureAgentSSEData("not-json"), []);
});

test("provider failures become generic Macky errors without sensitive bodies", () => {
  for (const type of ["error", "response.failed", "response.incomplete"]) {
    const normalized = normalizeAzureAgentSSEData(JSON.stringify({
      type,
      error: {
        message: "secret provider body",
        api_key: "do-not-leak",
      },
    }));
    assert.deepEqual(normalized, [{
      protocol_version: 1,
      kind: "error",
      error_detail: "Agent response unavailable.",
    }]);
    assert.equal(JSON.stringify(normalized).includes("secret provider body"), false);
    assert.equal(JSON.stringify(normalized).includes("do-not-leak"), false);
  }
});

test("SSE normalization preserves streaming across provider chunk boundaries", async () => {
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  let finishProviderStream: (() => void) | undefined;
  const providerStream = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(encoder.encode(
        "event: response.output_text.delta\r\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"First\"}\r\n\r\n"
      ));
      finishProviderStream = () => {
        controller.enqueue(encoder.encode("data: {\"type\":\"response.comp"));
        controller.enqueue(encoder.encode("leted\"}\n\n"));
        controller.close();
      };
    },
  });

  const reader = normalizeAzureAgentSSEStream(providerStream).getReader();
  const firstChunk = await reader.read();
  assert.equal(firstChunk.done, false);
  assert.deepEqual(JSON.parse(decoder.decode(firstChunk.value).slice("data: ".length)), {
    protocol_version: 1,
    kind: "text",
    text: "First",
  });

  assert.ok(finishProviderStream);
  finishProviderStream();
  const secondChunk = await reader.read();
  assert.equal(secondChunk.done, false);
  assert.deepEqual(JSON.parse(decoder.decode(secondChunk.value).slice("data: ".length)), {
    protocol_version: 1,
    kind: "completed",
  });
  assert.deepEqual(await reader.read(), { value: undefined, done: true });
});

test("SSE stream read failures emit one generic error frame", async () => {
  const providerStream = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.error(new Error("sensitive upstream failure"));
    },
  });
  const normalizedBody = await new Response(normalizeAzureAgentSSEStream(providerStream)).text();
  assert.equal(normalizedBody.includes("sensitive upstream failure"), false);
  assert.deepEqual(JSON.parse(normalizedBody.trim().slice("data: ".length)), {
    protocol_version: 1,
    kind: "error",
    error_detail: "Agent response unavailable.",
  });
});
