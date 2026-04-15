import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

import { waitForCodexReview } from './review_wait.mjs';

function writeJSON(path, obj) {
  writeFileSync(path, JSON.stringify(obj, null, 2) + '\n', 'utf8');
}

test('waitForCodexReview wakes immediately on an open interaction gate', async () => {
  const runsDir = mkdtempSync(join(tmpdir(), 'claudex-review-wait-'));
  const runId = 'run-1';
  const runDir = join(runsDir, runId);
  mkdirSync(join(runDir, 'responses'), { recursive: true });
  mkdirSync(join(runDir, 'queue'), { recursive: true });
  mkdirSync(join(runDir, 'turns'), { recursive: true });

  writeFileSync(join(runsDir, 'active-run'), `${runId}\n`, 'utf8');
  writeJSON(join(runDir, 'run.json'), {
    run_id: runId,
    project_root: '/tmp/project',
    project_slug: 'project',
    claude_session_id: 'sess-1',
    tmux_target: 'overnight:1.2',
    created_at: '2026-04-09T20:00:00Z',
  });
  writeJSON(join(runDir, 'status.json'), {
    state: 'inflight',
    control_mode: 'supervised',
    instruction_id: 'inst-1',
    updated_at: '2026-04-09T20:00:01Z',
  });
  writeJSON(join(runDir, 'inflight.json'), {
    instruction_id: 'inst-1',
    text: 'live work',
    submitted_at: '2026-04-09T20:00:01Z',
  });
  writeJSON(join(runDir, 'interaction-gate.json'), {
    gate_id: 'gate-1',
    status: 'open',
    gate_type: 'edit_approval',
    instruction_id: 'inst-1',
    tmux_target: 'overnight:1.2',
    prompt_excerpt: 'Do you want to make this edit to CLAUDE.md?',
    resolution_hint: 'Send the numeric choice shown by the harness.',
  });

  const result = await waitForCodexReview(
    runsDir,
    { timeoutMs: 200, pollIntervalMs: 10 },
    {},
  );

  assert.equal(result.status, 'review_needed');
  assert.equal(result.bridge_state, 'interaction_gate');
  assert.equal(result.instruction_id, 'inst-1');
  assert.equal(result.review.gate_type, 'edit_approval');
});

test('waitForCodexReview wakes immediately on a provider error gate', async () => {
  const runsDir = mkdtempSync(join(tmpdir(), 'claudex-review-wait-'));
  const runId = 'run-1';
  const runDir = join(runsDir, runId);
  mkdirSync(join(runDir, 'responses'), { recursive: true });
  mkdirSync(join(runDir, 'queue'), { recursive: true });
  mkdirSync(join(runDir, 'turns'), { recursive: true });

  writeFileSync(join(runsDir, 'active-run'), `${runId}\n`, 'utf8');
  writeJSON(join(runDir, 'run.json'), {
    run_id: runId,
    project_root: '/tmp/project',
    project_slug: 'project',
    claude_session_id: 'sess-1',
    tmux_target: 'overnight:1.2',
    created_at: '2026-04-09T20:00:00Z',
  });
  writeJSON(join(runDir, 'status.json'), {
    state: 'inflight',
    control_mode: 'supervised',
    instruction_id: 'inst-2',
    updated_at: '2026-04-09T20:00:01Z',
  });
  writeJSON(join(runDir, 'inflight.json'), {
    instruction_id: 'inst-2',
    text: 'live work',
    submitted_at: '2026-04-09T20:00:01Z',
  });
  writeJSON(join(runDir, 'interaction-gate.json'), {
    gate_id: 'gate-2',
    status: 'open',
    gate_type: 'provider_overload',
    instruction_id: 'inst-2',
    tmux_target: 'overnight:1.2',
    prompt_excerpt: 'API Error: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}',
    resolution_hint: 'No harness choice is available. Supervisor should inspect and retry or requeue the bounded slice.',
  });

  const result = await waitForCodexReview(
    runsDir,
    { timeoutMs: 200, pollIntervalMs: 10 },
    {},
  );

  assert.equal(result.status, 'review_needed');
  assert.equal(result.bridge_state, 'interaction_gate');
  assert.equal(result.instruction_id, 'inst-2');
  assert.equal(result.review.gate_type, 'provider_overload');
});
