import { appendFileSync, existsSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';

function readJSON(path) {
  if (!existsSync(path)) return null;
  return JSON.parse(readFileSync(path, 'utf8'));
}

function isProviderRecoveryGate(gate) {
  return (
    gate?.status === 'open'
    && (
      gate?.gate_type === 'provider_overload'
      || gate?.gate_type === 'provider_error'
    )
  );
}

function listQueuedInstructionEntries(runDir) {
  const queueDir = join(runDir, 'queue');
  if (!existsSync(queueDir)) return [];

  return readdirSync(queueDir)
    .filter((name) => name.endsWith('.json'))
    .sort()
    .map((name) => {
      const path = join(queueDir, name);
      return {
        path,
        instruction_id: readJSON(path)?.instruction_id ?? null,
      };
    });
}

function appendRunEvent(runDir, event) {
  appendFileSync(
    join(runDir, 'events.jsonl'),
    `${JSON.stringify({ ...event, ts: new Date().toISOString() })}\n`,
    'utf8',
  );
}

function prepareProviderRecovery(runDir, gate) {
  const inflightPath = join(runDir, 'inflight.json');
  const inflightInstructionId = readJSON(inflightPath)?.instruction_id ?? null;
  const queuedEntries = listQueuedInstructionEntries(runDir);

  if (existsSync(inflightPath)) {
    rmSync(inflightPath, { force: true });
  }

  for (const entry of queuedEntries) {
    rmSync(entry.path, { force: true });
  }

  appendRunEvent(runDir, {
    type: 'provider_recovery_prepared',
    gate_id: gate?.gate_id ?? null,
    gate_type: gate?.gate_type ?? null,
    cleared_inflight_instruction_id: inflightInstructionId,
    dropped_queue_instruction_ids: queuedEntries
      .map((entry) => entry.instruction_id)
      .filter(Boolean),
  });

  return {
    cleared_inflight_instruction_id: inflightInstructionId,
    dropped_queue_instruction_ids: queuedEntries
      .map((entry) => entry.instruction_id)
      .filter(Boolean),
  };
}

export {
  isProviderRecoveryGate,
  listQueuedInstructionEntries,
  prepareProviderRecovery,
};
