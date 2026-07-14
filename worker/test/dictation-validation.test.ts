import assert from "node:assert/strict";
import test from "node:test";
import {
  isAssemblyAIUpstreamOpeningAllowed,
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

test("dictation keyterms are deduplicated and capped to AssemblyAI limits", () => {
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

test("release before provider Begin never opens a billable upstream socket", () => {
  assert.equal(isAssemblyAIUpstreamOpeningAllowed(false, false), true);
  assert.equal(isAssemblyAIUpstreamOpeningAllowed(false, true), false);
  assert.equal(isAssemblyAIUpstreamOpeningAllowed(true, false), false);
});
