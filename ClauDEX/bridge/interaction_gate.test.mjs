import test from 'node:test';
import assert from 'node:assert/strict';

import {
  buildInteractionGate,
  buildInteractionGateReview,
  buildResolutionKeySequence,
  detectInteractionGate,
} from './interaction_gate.mjs';
import { reconcileBridgeSnapshot } from './status_reconcile.mjs';

test('detectInteractionGate recognises edit approval prompts', () => {
  const text = `
Do you want to make this edit to CLAUDE.md?
❯ 1. Yes
  2. Yes, and allow Claude to edit its own settings for this session
  3. No
`;
  const gate = detectInteractionGate(text, 'permission_prompt');
  assert.equal(gate.gate_type, 'edit_approval');
  assert.equal(gate.prompt_excerpt, 'Do you want to make this edit to CLAUDE.md?');
  assert.equal(gate.choices.length, 3);
  assert.equal(gate.selected_choice, '1');
  assert.equal(gate.choices[0].choice, '1');
  assert.equal(gate.choices[0].label, 'Yes');
  assert.equal(gate.choices[1].choice, '2');
});

test('detectInteractionGate recognises trust prompts even when classified as waiting_for_input', () => {
  const text = `
Do you trust the contents of this directory? Working with untrusted
contents comes with higher risk of prompt injection.

1. Yes, continue
2. No, quit
`;
  const gate = detectInteractionGate(text, 'waiting_for_input');
  assert.equal(gate.gate_type, 'trust_prompt');
  assert.equal(gate.choices.length, 2);
});

test('detectInteractionGate ignores the normal Claude permissions footer', () => {
  const text = `
Claude Code v2.1.100
❯
⏵⏵ bypass permissions on (shift+tab to cycle)
`;
  const gate = detectInteractionGate(text, 'permission_prompt');
  assert.equal(gate, null);
});

test('detectInteractionGate recognises provider overload failures as review gates', () => {
  const text = `
⏺ Now update the tests.
  ⎿  API Error: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}

❯
`;
  const gate = detectInteractionGate(text, 'waiting_for_input');
  assert.equal(gate.gate_type, 'provider_overload');
  assert.match(gate.prompt_excerpt, /overloaded_error/);
  assert.equal(gate.choices.length, 0);
});

test('detectInteractionGate ignores historical provider overload once work has resumed', () => {
  const text = `
⏺ Earlier step:
  ⎿  API Error: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}

❯ __BRAID_RELAY__

Read 2 files (ctrl+o to expand)

⏺ Now I have full context. Let me apply all production code changes first.

✶ Envisioning… (18s · ↓ 116 tokens)
`;
  const gate = detectInteractionGate(text, 'waiting_for_input');
  assert.equal(gate, null);
});

test('buildInteractionGateReview produces a supervisor-facing summary', () => {
  const gate = buildInteractionGate({
    run_id: 'run-1',
    bridge_state: 'inflight',
    instruction_id: 'inst-1',
    session_id: 'sess-1',
    tmux_target: 'overnight:1.2',
    text: 'Do you want to make this edit to CLAUDE.md?\n❯ 1. Yes\n  2. No',
    classification: 'permission_prompt',
    now: '2026-04-09T20:00:00Z',
  });
  const review = buildInteractionGateReview(gate);
  assert.equal(review.instruction_id, 'inst-1');
  assert.match(review.response, /Worker blocked on interaction gate/);
  assert.match(review.response, /CLAUDE\.md/);
  assert.match(review.response, /Current selection: 1/);
});

test('buildResolutionKeySequence uses selection-aware navigation for numbered prompts', () => {
  const gate = {
    selected_choice: '1',
  };
  assert.deepEqual(buildResolutionKeySequence(gate, '1'), ['Enter']);
  assert.deepEqual(buildResolutionKeySequence(gate, '3'), ['Down', 'Down', 'Enter']);
  assert.deepEqual(buildResolutionKeySequence({}, 'y'), ['y', 'Enter']);
});

test('reconcileBridgeSnapshot overlays open interaction gates as bridge state', () => {
  const gate = {
    status: 'open',
    gate_type: 'edit_approval',
    instruction_id: 'inst-2',
    tmux_target: 'overnight:1.2',
  };
  const snapshot = reconcileBridgeSnapshot(
    {
      state: 'inflight',
      control_mode: 'supervised',
      instruction_id: 'inst-2',
      inflight: { instruction_id: 'inst-2' },
      jeff_state: 'Working',
    },
    { interactionGate: gate },
  );
  assert.equal(snapshot.state, 'interaction_gate');
  assert.equal(snapshot.control_mode, 'review');
  assert.equal(snapshot.jeff_state, 'Needs Attention');
  assert.equal(snapshot.interaction_gate, gate);
});
