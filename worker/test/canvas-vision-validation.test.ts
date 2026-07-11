import assert from "node:assert/strict";
import test from "node:test";

import { validateCanvasVisionSequence } from "../src/index.ts";

function validSequence(): Record<string, unknown> {
  return {
    summary: "Point to the visible button.",
    title: "Button help",
    source_width: 1_000,
    source_height: 800,
    steps: [
      {
        narration_cue: "This is the button to use.",
        duration_ms: 4_000,
        clear_before_next: true,
        canvas: [
          {
            type: "highlight",
            x: 100,
            y: 100,
            width: 120,
            height: 40,
            to_x: null,
            to_y: null,
            points: null,
            text: null,
            animation: null,
          },
        ],
        cursor: null,
      },
    ],
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
  const spotlight = {
    type: "spotlight",
    x: 10,
    y: 10,
    width: 200,
    height: 200,
    to_x: null,
    to_y: null,
    points: null,
    text: null,
    animation: null,
  };
  step.canvas = [spotlight, { ...spotlight, x: 300 }];

  assert.match(validateCanvasVisionSequence(sequence, 1_000, 800) ?? "", /multiple spotlights/);
});

test("rejects labels longer than the Swift decoder accepts", () => {
  const sequence = validSequence();
  const step = (sequence.steps as Array<Record<string, unknown>>)[0];
  step.canvas = [
    {
      type: "label",
      x: 100,
      y: 100,
      width: null,
      height: null,
      to_x: null,
      to_y: null,
      points: null,
      text: "x".repeat(121),
      animation: null,
    },
  ];

  assert.match(validateCanvasVisionSequence(sequence, 1_000, 800) ?? "", /invalid text/);
});
