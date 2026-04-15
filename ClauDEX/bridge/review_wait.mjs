import { existsSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { buildInteractionGateReview, readInteractionGate } from './interaction_gate.mjs';

function readJSON(path) {
  if (!existsSync(path)) return null;
  return JSON.parse(readFileSync(path, 'utf8'));
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function getActiveRun(runsDir) {
  const pointerPath = join(runsDir, 'active-run');
  if (!existsSync(pointerPath)) return null;
  const runId = readFileSync(pointerPath, 'utf8').trim();
  if (!runId) return null;
  const runDir = join(runsDir, runId);
  const run = readJSON(join(runDir, 'run.json'));
  if (!run) return null;
  return { ...run, run_id: runId, run_dir: runDir };
}

function getLatestResponse(runId, runsDir) {
  const responsesDir = join(runsDir, runId, 'responses');
  if (!existsSync(responsesDir)) return null;

  const responses = readdirSync(responsesDir)
    .filter((name) => name.endsWith('.json'))
    .map((name) => readJSON(join(responsesDir, name)))
    .filter(Boolean)
    .sort((a, b) => (a.completed_at ?? '').localeCompare(b.completed_at ?? ''));

  return responses.length > 0 ? responses[responses.length - 1] : null;
}

function getReviewCursorPath(runDir) {
  return join(runDir, 'codex-review-cursor.json');
}

function readReviewCursor(runDir) {
  return readJSON(getReviewCursorPath(runDir));
}

function reviewMatchesCursor(review, cursor) {
  if (!review?.instruction_id || !cursor?.instruction_id) {
    return false;
  }
  if (review.instruction_id !== cursor.instruction_id) {
    return false;
  }
  if (review.completed_at && cursor.completed_at) {
    return review.completed_at === cursor.completed_at;
  }
  return true;
}

function markReviewConsumed(runDir, review, deliveryPath = 'cached') {
  if (!review?.instruction_id) {
    return;
  }
  writeFileSync(
    getReviewCursorPath(runDir),
    `${JSON.stringify(
      {
        instruction_id: review.instruction_id,
        completed_at: review.completed_at ?? null,
        delivery_path: deliveryPath,
        recorded_at: new Date().toISOString(),
      },
      null,
      2,
    )}\n`,
    'utf8',
  );
}

function getTrackedInstructionId(runId, runsDir) {
  const inflight = readJSON(join(runsDir, runId, 'inflight.json'));
  if (inflight?.instruction_id) return inflight.instruction_id;
  const status = readJSON(join(runsDir, runId, 'status.json'));
  if (status?.instruction_id) return status.instruction_id;
  return null;
}

function getQueuedInstructionIds(runId, runsDir) {
  const queueDir = join(runsDir, runId, 'queue');
  if (!existsSync(queueDir)) return [];

  return readdirSync(queueDir)
    .filter((name) => name.endsWith('.json'))
    .map((name) => readJSON(join(queueDir, name))?.instruction_id ?? null)
    .filter(Boolean)
    .sort();
}

function hasPendingWorkBeyondReview(runId, runsDir, reviewInstructionId) {
  const trackedInstructionId = getTrackedInstructionId(runId, runsDir);
  if (trackedInstructionId && trackedInstructionId !== reviewInstructionId) {
    return true;
  }

  return getQueuedInstructionIds(runId, runsDir).some(
    (instructionId) => instructionId !== reviewInstructionId,
  );
}

function getEffectiveBridgeState(runDir) {
  const status = readJSON(join(runDir, 'status.json')) ?? {};
  const inflight = readJSON(join(runDir, 'inflight.json'));
  const interactionGate = readInteractionGate(runDir);
  if (interactionGate?.status === 'open' && status.state !== 'waiting_for_codex') {
    return {
      status,
      inflight,
      interactionGate,
      state: 'interaction_gate',
    };
  }
  if (inflight?.instruction_id && status.state !== 'waiting_for_codex') {
    return {
      status,
      inflight,
      interactionGate,
      state: 'inflight',
    };
  }
  return {
    status,
    inflight,
    interactionGate,
    state: status.state ?? 'unknown',
  };
}

async function waitForCodexReview(
  runsDir,
  options = {},
  deps = {},
) {
  const timeoutMs = Number.isFinite(options.timeoutMs) ? Math.max(1, options.timeoutMs) : 300000;
  const pollIntervalMs = Number.isFinite(options.pollIntervalMs)
    ? Math.max(25, options.pollIntervalMs)
    : 250;
  const waitForResponse = deps.waitForResponse ?? null;
  const deadline = Date.now() + timeoutMs;

  while (Date.now() <= deadline) {
    const run = getActiveRun(runsDir);
    if (!run) {
      return {
        status: 'run_completed',
        run_id: null,
        instruction_id: null,
        bridge_state: 'inactive',
        review: null,
        delivery_path: 'poll',
      };
    }

    const bridgeState = getEffectiveBridgeState(run.run_dir);
    if (bridgeState.state === 'interaction_gate') {
      return {
        status: 'review_needed',
        run_id: run.run_id,
        instruction_id:
          bridgeState.interactionGate?.instruction_id
          ?? getTrackedInstructionId(run.run_id, runsDir),
        bridge_state: 'interaction_gate',
        review: buildInteractionGateReview(bridgeState.interactionGate),
        delivery_path: 'poll',
      };
    }
    if (bridgeState.state === 'waiting_for_codex') {
      const latestReview = getLatestResponse(run.run_id, runsDir);
      if (!latestReview) {
        await sleep(pollIntervalMs);
        continue;
      }
      if (reviewMatchesCursor(latestReview, readReviewCursor(run.run_dir))) {
        await sleep(pollIntervalMs);
        continue;
      }
      if (hasPendingWorkBeyondReview(run.run_id, runsDir, latestReview.instruction_id)) {
        await sleep(pollIntervalMs);
        continue;
      }
      markReviewConsumed(run.run_dir, latestReview, 'cached');
      return {
        status: 'review_needed',
        run_id: run.run_id,
        instruction_id: getTrackedInstructionId(run.run_id, runsDir),
        bridge_state: 'waiting_for_codex',
        review: latestReview,
        delivery_path: 'cached',
      };
    }

    const trackedInstructionId = getTrackedInstructionId(run.run_id, runsDir);
    if (
      waitForResponse
      && trackedInstructionId
      && (bridgeState.state === 'queued' || bridgeState.state === 'inflight')
    ) {
      const remainingMs = Math.max(1, deadline - Date.now());
      const waitSliceMs = Math.min(remainingMs, 1000);
      const responseResult = await waitForResponse(
        run.run_id,
        trackedInstructionId,
        { timeoutMs: waitSliceMs },
        runsDir,
      );
      if (responseResult.status === 'completed') {
        const deliveredReview = responseResult.response ?? getLatestResponse(run.run_id, runsDir) ?? null;
        markReviewConsumed(run.run_dir, deliveredReview, responseResult.delivery_path ?? 'poll');
        return {
          status: 'review_needed',
          run_id: run.run_id,
          instruction_id: trackedInstructionId,
          bridge_state: 'waiting_for_codex',
          review: deliveredReview,
          delivery_path: responseResult.delivery_path ?? 'poll',
        };
      }
      if (responseResult.status === 'run_completed') {
        return {
          status: 'run_completed',
          run_id: run.run_id,
          instruction_id: trackedInstructionId,
          bridge_state: bridgeState.state,
          review: null,
          delivery_path: responseResult.delivery_path ?? 'poll',
        };
      }
      if (responseResult.status === 'timeout') {
        await sleep(pollIntervalMs);
        continue;
      }
    }

    await sleep(pollIntervalMs);
  }

  return {
    status: 'timeout',
    run_id: getActiveRun(runsDir)?.run_id ?? null,
    instruction_id: null,
    bridge_state: 'unknown',
    review: null,
    delivery_path: 'poll',
  };
}

export {
  getActiveRun,
  getLatestResponse,
  markReviewConsumed,
  readReviewCursor,
  reviewMatchesCursor,
  getTrackedInstructionId,
  waitForCodexReview,
};
