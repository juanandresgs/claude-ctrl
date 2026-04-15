import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

import {
  isProviderRecoveryGate,
  listQueuedInstructionEntries,
  prepareProviderRecovery,
} from './provider_recovery.mjs';

function writeJSON(path, obj) {
  writeFileSync(path, JSON.stringify(obj, null, 2) + '\n', 'utf8');
}

test('isProviderRecoveryGate matches provider error gate types only', () => {
  assert.equal(isProviderRecoveryGate({ status: 'open', gate_type: 'provider_overload' }), true);
  assert.equal(isProviderRecoveryGate({ status: 'open', gate_type: 'provider_error' }), true);
  assert.equal(isProviderRecoveryGate({ status: 'open', gate_type: 'edit_approval' }), false);
  assert.equal(isProviderRecoveryGate({ status: 'resolved', gate_type: 'provider_overload' }), false);
});

test('prepareProviderRecovery clears stale inflight and queued retries', () => {
  const runDir = mkdtempSync(join(tmpdir(), 'claudex-provider-recovery-'));
  mkdirSync(join(runDir, 'queue'), { recursive: true });
  writeJSON(join(runDir, 'inflight.json'), {
    instruction_id: 'inst-inflight',
  });
  writeJSON(join(runDir, 'queue', 'a.json'), {
    instruction_id: 'inst-a',
  });
  writeJSON(join(runDir, 'queue', 'b.json'), {
    instruction_id: 'inst-b',
  });

  const result = prepareProviderRecovery(runDir, {
    gate_id: 'gate-1',
    gate_type: 'provider_overload',
  });

  assert.equal(result.cleared_inflight_instruction_id, 'inst-inflight');
  assert.deepEqual(result.dropped_queue_instruction_ids, ['inst-a', 'inst-b']);
  assert.deepEqual(listQueuedInstructionEntries(runDir), []);
  assert.equal(readFileSync(join(runDir, 'events.jsonl'), 'utf8').includes('provider_recovery_prepared'), true);
});
