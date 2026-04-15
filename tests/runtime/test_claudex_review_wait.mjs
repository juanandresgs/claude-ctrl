import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

import { waitForCodexReview } from '../../ClauDEX/bridge/review_wait.mjs';

function makeRunsDir() {
  const root = mkdtempSync(join(tmpdir(), 'claudex-review-wait-'));
  const runsDir = join(root, 'runs');
  mkdirSync(runsDir, { recursive: true });
  return {
    root,
    runsDir,
    cleanup() {
      rmSync(root, { recursive: true, force: true });
    },
  };
}

function writeJson(path, value) {
  writeFileSync(path, `${JSON.stringify(value)}\n`, 'utf8');
}

function seedActiveRun(
  runsDir,
  {
    runId = 'run-demo',
    state = 'waiting_for_codex',
    updatedAt = '2026-04-08T06:00:00Z',
    statusInstructionId = null,
    inflightInstructionId = null,
    response = null,
    queuedInstructionIds = [],
  } = {},
) {
  const runDir = join(runsDir, runId);
  mkdirSync(join(runDir, 'responses'), { recursive: true });
  mkdirSync(join(runDir, 'queue'), { recursive: true });

  writeFileSync(join(runsDir, 'active-run'), `${runId}\n`, 'utf8');
  writeJson(join(runDir, 'run.json'), {
    project_root: '/tmp/fake-project',
    project_slug: 'fake-project',
    created_at: updatedAt,
    completed_at: null,
    tmux_target: 'overnight:1.2',
  });

  const statusPayload = { state, updated_at: updatedAt };
  if (statusInstructionId) {
    statusPayload.instruction_id = statusInstructionId;
  }
  writeJson(join(runDir, 'status.json'), statusPayload);

  if (inflightInstructionId) {
    writeJson(join(runDir, 'inflight.json'), {
      instruction_id: inflightInstructionId,
      queued_at: updatedAt,
      claimed_at: updatedAt,
      text: 'demo instruction',
    });
  }

  if (response) {
    writeJson(join(runDir, 'responses', '0001-response.json'), response);
  }

  for (const instructionId of queuedInstructionIds) {
    writeJson(join(runDir, 'queue', `${instructionId}.json`), {
      instruction_id: instructionId,
      text: `queued ${instructionId}`,
      queued_at: updatedAt,
    });
  }

  return { runId, runDir };
}

test('waitForCodexReview returns run_completed when no active run exists', async () => {
  const env = makeRunsDir();
  try {
    const result = await waitForCodexReview(env.runsDir, {
      timeoutMs: 30,
      pollIntervalMs: 5,
    });

    assert.equal(result.status, 'run_completed');
    assert.equal(result.run_id, null);
    assert.equal(result.bridge_state, 'inactive');
    assert.equal(result.review, null);
  } finally {
    env.cleanup();
  }
});

test('waitForCodexReview returns cached review immediately when bridge is waiting_for_codex', async () => {
  const env = makeRunsDir();
  try {
    seedActiveRun(env.runsDir, {
      state: 'waiting_for_codex',
      statusInstructionId: 'inst-cached',
      response: {
        instruction_id: 'inst-cached',
        completed_at: '2026-04-08T06:01:00Z',
        response: 'Claude completed the bounded slice.',
      },
    });

    const result = await waitForCodexReview(env.runsDir, {
      timeoutMs: 30,
      pollIntervalMs: 5,
    });

    assert.equal(result.status, 'review_needed');
    assert.equal(result.run_id, 'run-demo');
    assert.equal(result.instruction_id, 'inst-cached');
    assert.equal(result.bridge_state, 'waiting_for_codex');
    assert.equal(result.delivery_path, 'cached');
    assert.equal(result.review.instruction_id, 'inst-cached');
    assert.match(result.review.response, /bounded slice/);
  } finally {
    env.cleanup();
  }
});

test('waitForCodexReview ignores cached review when newer queued work exists', async () => {
  const env = makeRunsDir();
  try {
    seedActiveRun(env.runsDir, {
      state: 'waiting_for_codex',
      statusInstructionId: 'inst-cached',
      response: {
        instruction_id: 'inst-cached',
        completed_at: '2026-04-08T06:01:00Z',
        response: 'Claude completed the bounded slice.',
      },
      queuedInstructionIds: ['inst-newer'],
    });

    const result = await waitForCodexReview(env.runsDir, {
      timeoutMs: 40,
      pollIntervalMs: 5,
    });

    assert.equal(result.status, 'timeout');
    assert.equal(result.run_id, 'run-demo');
    assert.equal(result.review, null);
  } finally {
    env.cleanup();
  }
});

test('waitForCodexReview does not redeliver a cached review after it has been consumed', async () => {
  const env = makeRunsDir();
  try {
    const { runDir } = seedActiveRun(env.runsDir, {
      state: 'waiting_for_codex',
      statusInstructionId: 'inst-cached',
      response: {
        instruction_id: 'inst-cached',
        completed_at: '2026-04-08T06:01:00Z',
        response: 'Claude completed the bounded slice.',
      },
    });

    const first = await waitForCodexReview(env.runsDir, {
      timeoutMs: 30,
      pollIntervalMs: 5,
    });
    assert.equal(first.status, 'review_needed');

    const cursor = JSON.parse(
      readFileSync(join(runDir, 'codex-review-cursor.json'), 'utf8'),
    );
    assert.equal(cursor.instruction_id, 'inst-cached');

    const second = await waitForCodexReview(env.runsDir, {
      timeoutMs: 40,
      pollIntervalMs: 5,
    });
    assert.equal(second.status, 'timeout');
    assert.equal(second.review, null);
  } finally {
    env.cleanup();
  }
});

test('waitForCodexReview delegates to waitForResponse while Claude is still working', async () => {
  const env = makeRunsDir();
  try {
    seedActiveRun(env.runsDir, {
      state: 'inflight',
      inflightInstructionId: 'inst-broker',
    });

    let call = null;
    const result = await waitForCodexReview(
      env.runsDir,
      {
        timeoutMs: 50,
        pollIntervalMs: 5,
      },
      {
        waitForResponse: async (runId, instructionId, options, runsDir) => {
          call = { runId, instructionId, options, runsDir };
          return {
            status: 'completed',
            delivery_path: 'broker',
            response: {
              instruction_id: instructionId,
              completed_at: '2026-04-08T06:02:00Z',
              response: 'Claude finished after broker wake.',
            },
          };
        },
      },
    );

    assert.deepEqual(call.runId, 'run-demo');
    assert.deepEqual(call.instructionId, 'inst-broker');
    assert.equal(call.runsDir, env.runsDir);

    assert.equal(result.status, 'review_needed');
    assert.equal(result.delivery_path, 'broker');
    assert.equal(result.instruction_id, 'inst-broker');
    assert.equal(result.review.instruction_id, 'inst-broker');
    assert.match(result.review.response, /broker wake/);
  } finally {
    env.cleanup();
  }
});

test('waitForCodexReview prefers inflight instruction when status has been clobbered back to queued', async () => {
  const env = makeRunsDir();
  try {
    seedActiveRun(env.runsDir, {
      state: 'queued',
      statusInstructionId: 'inst-stale-queued',
      inflightInstructionId: 'inst-real-inflight',
    });

    let call = null;
    const result = await waitForCodexReview(
      env.runsDir,
      {
        timeoutMs: 50,
        pollIntervalMs: 5,
      },
      {
        waitForResponse: async (runId, instructionId, options, runsDir) => {
          call = { runId, instructionId, options, runsDir };
          return {
            status: 'timeout',
            delivery_path: 'poll',
          };
        },
      },
    );

    assert.equal(call.runId, 'run-demo');
    assert.equal(call.instructionId, 'inst-real-inflight');
    assert.equal(call.runsDir, env.runsDir);
    assert.equal(result.status, 'timeout');
    assert.equal(result.bridge_state, 'inflight');
    assert.equal(result.instruction_id, 'inst-real-inflight');
  } finally {
    env.cleanup();
  }
});

test('waitForCodexReview times out when an active run has nothing ready to review', async () => {
  const env = makeRunsDir();
  try {
    seedActiveRun(env.runsDir, {
      state: 'idle',
    });

    const result = await waitForCodexReview(env.runsDir, {
      timeoutMs: 40,
      pollIntervalMs: 5,
    });

    assert.equal(result.status, 'timeout');
    assert.equal(result.run_id, 'run-demo');
  } finally {
    env.cleanup();
  }
});
