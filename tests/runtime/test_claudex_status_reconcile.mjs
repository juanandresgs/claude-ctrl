import assert from 'node:assert/strict';
import test from 'node:test';

import { reconcileBridgeSnapshot } from '../../ClauDEX/bridge/status_reconcile.mjs';

test('reconcileBridgeSnapshot prefers inflight instruction over stale queued status', () => {
  const snapshot = reconcileBridgeSnapshot({
    bridge: 'active',
    state: 'queued',
    control_mode: 'supervised',
    instruction_id: 'inst-stale-queued',
    inflight: {
      instruction_id: 'inst-real-inflight',
      text_preview: 'doing real work',
      submitted_at: '2026-04-08T21:37:29Z',
    },
  });

  assert.equal(snapshot.state, 'inflight');
  assert.equal(snapshot.instruction_id, 'inst-real-inflight');
});

test('reconcileBridgeSnapshot preserves waiting_for_codex even if inflight is absent', () => {
  const snapshot = reconcileBridgeSnapshot({
    bridge: 'active',
    state: 'waiting_for_codex',
    control_mode: 'review',
    instruction_id: null,
    inflight: null,
  });

  assert.equal(snapshot.state, 'waiting_for_codex');
  assert.equal(snapshot.instruction_id, null);
});
