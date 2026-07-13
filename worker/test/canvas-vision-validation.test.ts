import assert from "node:assert/strict";
import test from "node:test";

import { sanitizeCanvasVisionTargets, validateCanvasVisionSequence } from "../src/index.ts";

function validCommand(): Record<string, unknown> {
  return {
    type: "highlight",
    x: 100,
    y: 100,
    width: 120,
    height: 40,
    to_x: null,
    to_y: null,
    points: null,
    text: null,
    target_id: null,
    from_target_id: null,
    to_target_id: null,
    animation: null,
  };
}

function validStep(): Record<string, unknown> {
  return {
    narration_cue: "This is the button to use.",
    duration_ms: 4_000,
    clear_before_next: true,
    advance: "timed",
    canvas: [validCommand()],
    cursor: null,
  };
}

function validSequence(): Record<string, unknown> {
  return {
    summary: "Point to the visible button.",
    title: "Button help",
    source_width: 1_000,
    source_height: 800,
    continue_after_user_action: false,
    steps: [validStep()],
  };
}

test("accepts a valid visual guidance sequence", () => {
  assert.equal(validateCanvasVisionSequence(validSequence(), 1_000, 800), null);
});

test("rejects coordinates outside the screenshot", () => {
  const sequence = validSequence();
  const command = ((sequence.steps as Array<Record<string, unknown>>)[0].canvas as Array<Record<string, unknown>>)[0];
  command.x = 950;
  command.width = 100;

  assert.match(validateCanvasVisionSequence(sequence, 1_000, 800) ?? "", /out-of-bounds/);
});

test("rejects multiple spotlights in one step", () => {
  const sequence = validSequence();
  const step = (sequence.steps as Array<Record<string, unknown>>)[0];
  const spotlight = { ...validCommand(), type: "spotlight", x: 10, y: 10, width: 200, height: 200 };
  step.canvas = [spotlight, { ...spotlight, x: 300 }];

  assert.match(validateCanvasVisionSequence(sequence, 1_000, 800) ?? "", /multiple spotlights/);
});

test("rejects labels longer than the Swift decoder accepts", () => {
  const sequence = validSequence();
  const step = (sequence.steps as Array<Record<string, unknown>>)[0];
  step.canvas = [{ ...validCommand(), type: "label", width: null, height: null, text: "x".repeat(121) }];

  assert.match(validateCanvasVisionSequence(sequence, 1_000, 800) ?? "", /invalid text/);
});

test("accepts source dimensions off by one", () => {
  const sequence = validSequence();
  sequence.source_width = 999;
  sequence.source_height = 801;

  assert.equal(validateCanvasVisionSequence(sequence, 1_000, 800), null);
});

test("rejects source dimensions off by more than one", () => {
  const sequence = validSequence();
  sequence.source_width = 998;

  assert.match(validateCanvasVisionSequence(sequence, 1_000, 800) ?? "", /mismatched source dimensions/);
});

test("accepts a final on_user_action step with continuation", () => {
  const sequence = validSequence();
  sequence.continue_after_user_action = true;
  sequence.steps = [validStep(), { ...validStep(), advance: "on_user_action" }];

  assert.equal(validateCanvasVisionSequence(sequence, 1_000, 800), null);
});

test("rejects on_user_action on a non-final step", () => {
  const sequence = validSequence();
  sequence.steps = [{ ...validStep(), advance: "on_user_action" }, validStep()];

  assert.match(validateCanvasVisionSequence(sequence, 1_000, 800) ?? "", /non-final step/);
});

test("rejects two on_user_action steps", () => {
  const sequence = validSequence();
  sequence.steps = [
    { ...validStep(), advance: "on_user_action" },
    { ...validStep(), advance: "on_user_action" },
  ];

  assert.match(validateCanvasVisionSequence(sequence, 1_000, 800) ?? "", /non-final step/);
});

test("rejects continue_after_user_action with a timed final step", () => {
  const sequence = validSequence();
  sequence.continue_after_user_action = true;

  assert.match(validateCanvasVisionSequence(sequence, 1_000, 800) ?? "", /without a final on_user_action step/);
});

test("rejects an unknown advance value", () => {
  const sequence = validSequence();
  (sequence.steps as Array<Record<string, unknown>>)[0].advance = "hover";

  assert.match(validateCanvasVisionSequence(sequence, 1_000, 800) ?? "", /invalid advance/);
});

test("accepts a highlight via a provided target id", () => {
  const sequence = validSequence();
  const command = ((sequence.steps as Array<Record<string, unknown>>)[0].canvas as Array<Record<string, unknown>>)[0];
  command.x = null;
  command.y = null;
  command.width = null;
  command.height = null;
  command.target_id = "ax_1_3";

  assert.equal(validateCanvasVisionSequence(sequence, 1_000, 800, new Set(["ax_1_3"])), null);
});

test("rejects a target id that was not provided", () => {
  const sequence = validSequence();
  const command = ((sequence.steps as Array<Record<string, unknown>>)[0].canvas as Array<Record<string, unknown>>)[0];
  command.target_id = "ax_1_99";

  assert.match(validateCanvasVisionSequence(sequence, 1_000, 800, new Set(["ax_1_3"])) ?? "", /unknown target/);
});

test("rejects a target id when no targets were provided", () => {
  const sequence = validSequence();
  const command = ((sequence.steps as Array<Record<string, unknown>>)[0].canvas as Array<Record<string, unknown>>)[0];
  command.target_id = "ax_1_3";

  assert.match(validateCanvasVisionSequence(sequence, 1_000, 800) ?? "", /unknown target/);
});

test("accepts an arrow via from/to target ids", () => {
  const sequence = validSequence();
  const step = (sequence.steps as Array<Record<string, unknown>>)[0];
  step.canvas = [{
    ...validCommand(),
    type: "arrow",
    x: null,
    y: null,
    width: null,
    height: null,
    from_target_id: "ax_1_1",
    to_target_id: "ax_1_2",
  }];

  assert.equal(validateCanvasVisionSequence(sequence, 1_000, 800, new Set(["ax_1_1", "ax_1_2"])), null);
});

test("rejects an arrow with only one resolvable target id", () => {
  const sequence = validSequence();
  const step = (sequence.steps as Array<Record<string, unknown>>)[0];
  step.canvas = [{
    ...validCommand(),
    type: "arrow",
    x: null,
    y: null,
    width: null,
    height: null,
    from_target_id: "ax_1_1",
    to_target_id: null,
  }];

  assert.match(validateCanvasVisionSequence(sequence, 1_000, 800, new Set(["ax_1_1"])) ?? "", /unknown target/);
});

test("sanitizes targets: drops invalid entries, keeps valid ones", () => {
  const targets = sanitizeCanvasVisionTargets(
    [
      { id: "ok_1", role: "AXButton", label: "History", x: 10, y: 10, width: 100, height: 30 },
      { id: "", role: "AXButton", label: null, x: 10, y: 10, width: 100, height: 30 },
      { id: "off_screen", role: "AXButton", label: null, x: 990, y: 10, width: 100, height: 30 },
      { id: "ok_1", role: "AXButton", label: "duplicate id", x: 10, y: 10, width: 100, height: 30 },
      { id: "ok_2", role: "AXLink", label: "x".repeat(400), x: 0, y: 0, width: 50, height: 20 },
    ],
    1_000,
    800,
  );

  assert.deepEqual(targets.map((target) => target.id), ["ok_1", "ok_2"]);
  assert.equal(targets[1].label?.length, 120);
});

test("sanitizes targets: non-array input yields empty list", () => {
  assert.deepEqual(sanitizeCanvasVisionTargets({ id: "x" }, 1_000, 800), []);
});
