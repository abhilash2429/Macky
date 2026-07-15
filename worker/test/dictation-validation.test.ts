import assert from "node:assert/strict";
import test from "node:test";
import {
  dictationSessionUpdate,
  isDictationCommitMessage,
  parseDictationAudioMessage,
  parseDictationStartMessage,
  sanitizeDictationKeyterms,
} from "../src/index.ts";

test("dictation start forwards only safe surface configuration", () => {
  const start = parseDictationStartMessage(JSON.stringify({
    type: "dictation.start",
    surface_kind: "email",
    formatting_mode: "literal",
    keyterms: ["Macky", "api.example.com"],
    window_title: "Private email subject",
    selected_text: "Sensitive draft",
    url: "https://mail.google.com/mail/u/0/#inbox",
  }));

  assert.deepEqual(start, {
    type: "dictation.start",
    surfaceKind: "email",
    formattingMode: "literal",
    keyterms: ["Macky", "api.example.com"],
  });
});

test("dictation keyterms are deduplicated and capped to dictation limits", () => {
  const keyterms = sanitizeDictationKeyterms([
    "Macky",
    "Macky",
    "",
    "x".repeat(51),
    ...Array.from({ length: 140 }, (_, index) => `term-${index}`),
  ]);

  assert.equal(keyterms[0], "Macky");
  assert.equal(keyterms.length, 100);
  assert.equal(keyterms.includes("x".repeat(51)), false);
});

test("dictation start rejects unsupported surfaces and formatting modes", () => {
  assert.equal(parseDictationStartMessage(JSON.stringify({
    type: "dictation.start",
    surface_kind: "unknown",
    formatting_mode: "literal",
  })), null);
  assert.equal(parseDictationStartMessage(JSON.stringify({
    type: "dictation.start",
    surface_kind: "generic",
    formatting_mode: "rewrite_everything",
  })), null);
});

test("dictation accepts only bounded audio chunks and one explicit commit command", () => {
  assert.deepEqual(parseDictationAudioMessage(JSON.stringify({
    type: "dictation.audio",
    audio: "AA==",
  })), {
    type: "dictation.audio",
    audio: "AA==",
  });
  assert.equal(parseDictationAudioMessage(JSON.stringify({
    type: "response.create",
    audio: "AA==",
  })), null);
  assert.equal(parseDictationAudioMessage(JSON.stringify({
    type: "dictation.audio",
    audio: "x".repeat(64_001),
  })), null);
  assert.equal(isDictationCommitMessage("{\"type\":\"dictation.commit\"}"), true);
  assert.equal(isDictationCommitMessage("{\"type\":\"response.create\"}"), false);
});

test("dictation configures a text-only tool-free 24 kHz realtime session", () => {
  const start = parseDictationStartMessage(JSON.stringify({
    type: "dictation.start",
    surface_kind: "code",
    formatting_mode: "literal",
    keyterms: ["Macky"],
  }));
  assert.ok(start);

  const update = dictationSessionUpdate(start);
  const session = update.session as {
    model: string;
    output_modalities: string[];
    audio: { input: { format: { type: string; rate: number }; turn_detection: null } };
    tools: unknown[];
    tool_choice: string;
    tracing: null;
  };

  assert.equal(session.model, "gpt-realtime-2.1-mini");
  assert.deepEqual(session.output_modalities, ["text"]);
  assert.equal(session.audio.input.format.type, "audio/pcm");
  assert.equal(session.audio.input.format.rate, 24_000);
  assert.equal(session.audio.input.turn_detection, null);
  assert.deepEqual(session.tools, []);
  assert.equal(session.tool_choice, "none");
  assert.equal(session.tracing, null);
});
