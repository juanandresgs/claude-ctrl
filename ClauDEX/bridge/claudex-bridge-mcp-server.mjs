#!/usr/bin/env node

import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

import {
  markReviewConsumed,
  readReviewCursor,
  waitForCodexReview,
} from './review_wait.mjs';
import { clearInteractionGate, readInteractionGate } from './interaction_gate.mjs';
import { isProviderRecoveryGate, prepareProviderRecovery } from './provider_recovery.mjs';
import { reconcileBridgeSnapshot } from './status_reconcile.mjs';

function resolveBraidRoot() {
  const hintPath = join(process.cwd(), '.claude', 'claudex', 'braid-root');
  if (existsSync(hintPath)) {
    const hinted = readFileSync(hintPath, 'utf8').trim();
    if (hinted) {
      return hinted;
    }
  }
  if (process.env.BRAID_ROOT) {
    return process.env.BRAID_ROOT;
  }
  throw new Error(
    'BRAID_ROOT is required, or write the braid root path to .claude/claudex/braid-root.',
  );
}

const BRAID_ROOT = resolveBraidRoot();

async function importFromBraid(relativePath) {
  const fullPath = join(BRAID_ROOT, relativePath);
  return import(pathToFileURL(fullPath).href);
}

const [
  sdkServer,
  sdkStdio,
  sdkTypes,
  stateMod,
  observerMod,
] = await Promise.all([
  importFromBraid('node_modules/@modelcontextprotocol/sdk/dist/esm/server/index.js'),
  importFromBraid('node_modules/@modelcontextprotocol/sdk/dist/esm/server/stdio.js'),
  importFromBraid('node_modules/@modelcontextprotocol/sdk/dist/esm/types.js'),
  importFromBraid('lib/state.mjs'),
  importFromBraid('lib/observer.mjs'),
]);

const { Server } = sdkServer;
const { StdioServerTransport } = sdkStdio;
const { ListToolsRequestSchema, CallToolRequestSchema } = sdkTypes;
const {
  getActiveRun,
  queueInstruction,
  getResponse,
  waitForResponse,
  getConversation,
  getBridgeSnapshot,
  DEFAULT_RUNS_DIR,
} = stateMod;
const {
  captureSnapshot,
  getLatestSnapshot,
  getLatestSnapshotText,
  classifyWorkerState,
} = observerMod;

const TOOLS = [
  {
    name: 'send_instruction',
    description: 'Queue an instruction for Claude Code via the active bridge run.',
    inputSchema: {
      type: 'object',
      properties: {
        text: { type: 'string', description: 'Instruction text to queue.' },
      },
      required: ['text'],
    },
  },
  {
    name: 'get_status',
    description: 'Return the rich bridge snapshot for the active run.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'get_response',
    description: 'Return completed Claude responses for the active run.',
    inputSchema: {
      type: 'object',
      properties: {
        since_instruction_id: {
          type: 'string',
          description: 'Return only responses after this instruction id.',
        },
      },
    },
  },
  {
    name: 'wait_for_response',
    description: 'Wait for a specific queued instruction to complete.',
    inputSchema: {
      type: 'object',
      properties: {
        instruction_id: { type: 'string' },
        timeout_ms: { type: 'number' },
      },
      required: ['instruction_id'],
    },
  },
  {
    name: 'wait_for_codex_review',
    description:
      'Block until the bridge has review work for Codex. If Claude is already working, this waits through completion and returns the review payload when the run reaches waiting_for_codex.',
    inputSchema: {
      type: 'object',
      properties: {
        timeout_ms: { type: 'number', description: 'Maximum wait time in milliseconds.' },
      },
    },
  },
  {
    name: 'get_conversation',
    description: 'Return recent or full Codex/Claude turn history for the active run.',
    inputSchema: {
      type: 'object',
      properties: {
        last_n: { type: 'number' },
      },
    },
  },
  {
    name: 'get_worker_observer',
    description: 'Capture or read the Claude worker pane observer snapshot.',
    inputSchema: {
      type: 'object',
      properties: {
        capture: { type: 'boolean' },
      },
    },
  },
];

function requireActiveRun() {
  const run = getActiveRun(DEFAULT_RUNS_DIR);
  if (!run) {
    throw new Error('No active bridge run found.');
  }
  return run;
}

async function handleSendInstruction(args) {
  const text = args?.text;
  if (!text || typeof text !== 'string' || text.trim() === '') {
    throw new Error('send_instruction requires a non-empty "text" argument.');
  }

  const run = requireActiveRun();
  const runDir = run.run_dir ?? join(DEFAULT_RUNS_DIR, run.run_id);
  const interactionGate = readInteractionGate(runDir);
  let recovery = null;

  if (interactionGate?.status === 'open') {
    if (isProviderRecoveryGate(interactionGate)) {
      recovery = prepareProviderRecovery(runDir, interactionGate);
      clearInteractionGate(runDir);
    } else {
      return {
        run_id: run.run_id,
        instruction_id: interactionGate.instruction_id ?? null,
        status: 'blocked',
        reason: 'interaction_gate_open',
        interaction_gate: interactionGate,
      };
    }
  }

  const { instruction_id, queued_at } = queueInstruction(run.run_id, text, DEFAULT_RUNS_DIR);
  return {
    run_id: run.run_id,
    instruction_id,
    queued_at,
    status: 'queued',
    recovery,
  };
}

async function handleGetStatus() {
  const snapshot = await getBridgeSnapshot(DEFAULT_RUNS_DIR);
  const run = getActiveRun(DEFAULT_RUNS_DIR);
  const interactionGate = run ? readInteractionGate(run.run_dir) : null;
  return reconcileBridgeSnapshot(snapshot, { interactionGate });
}

async function handleGetResponse(args) {
  const run = requireActiveRun();
  const responses = getResponse(run.run_id, args?.since_instruction_id ?? null, DEFAULT_RUNS_DIR);
  if (args?.since_instruction_id) {
    return { run_id: run.run_id, responses, count: responses.length };
  }

  const cursor = readReviewCursor(run.run_dir);
  const filtered = responses.filter((response) => {
    if (!cursor) {
      return true;
    }
    const responseCompletedAt = response?.completed_at ?? '';
    const cursorCompletedAt = cursor?.completed_at ?? '';
    if (responseCompletedAt && cursorCompletedAt) {
      if (responseCompletedAt > cursorCompletedAt) return true;
      if (responseCompletedAt < cursorCompletedAt) return false;
    }
    return response?.instruction_id !== cursor?.instruction_id;
  });
  if (filtered.length > 0) {
    markReviewConsumed(run.run_dir, filtered[filtered.length - 1], 'get_response');
  }
  return { run_id: run.run_id, responses: filtered, count: filtered.length };
}

async function handleWaitForResponse(args) {
  const run = requireActiveRun();
  const instructionId = args?.instruction_id ?? null;
  if (!instructionId || typeof instructionId !== 'string' || instructionId.trim() === '') {
    throw new Error('wait_for_response requires a non-empty "instruction_id" argument.');
  }
  const timeoutMs = typeof args?.timeout_ms === 'number' ? args.timeout_ms : undefined;
  const result = await waitForResponse(run.run_id, instructionId, { timeoutMs }, DEFAULT_RUNS_DIR);
  return { run_id: run.run_id, instruction_id: instructionId, ...result };
}

async function handleWaitForCodexReview(args) {
  const timeoutMs = typeof args?.timeout_ms === 'number' ? args.timeout_ms : undefined;
  return waitForCodexReview(
    DEFAULT_RUNS_DIR,
    { timeoutMs },
    { waitForResponse },
  );
}

async function handleGetConversation(args) {
  const run = requireActiveRun();
  const lastN = typeof args?.last_n === 'number' && args.last_n > 0 ? args.last_n : null;
  const turns = getConversation(run.run_id, lastN, DEFAULT_RUNS_DIR);
  return { run_id: run.run_id, turns, count: turns.length };
}

async function handleGetWorkerObserver(args) {
  const run = requireActiveRun();
  const shouldCapture = args?.capture === true;
  let meta = null;
  let text = null;

  if (shouldCapture) {
    const paneId = run.claude_pane_id ?? null;
    if (!paneId) {
      return {
        run_id: run.run_id,
        observer: 'unavailable',
        reason: 'No claude_pane_id stored in run.json.',
      };
    }
    meta = captureSnapshot(run.run_dir, paneId, 'mcp_request');
    if (!meta) {
      return {
        run_id: run.run_id,
        observer: 'capture_failed',
        reason: 'tmux capture-pane failed.',
      };
    }
    text = getLatestSnapshotText(run.run_dir);
  } else {
    meta = getLatestSnapshot(run.run_dir);
    text = getLatestSnapshotText(run.run_dir);
  }

  if (!meta) {
    return {
      run_id: run.run_id,
      observer: 'no_snapshot',
      message: 'No observer snapshot yet. Call with capture: true to take one.',
    };
  }

  return {
    run_id: run.run_id,
    observer: {
      timestamp: meta.timestamp,
      trigger: meta.trigger,
      classification: meta.classification ?? classifyWorkerState(text ?? ''),
      artifacts: meta.artifacts ?? null,
      text,
    },
  };
}

const server = new Server(
  { name: 'claudex-bridge', version: '0.1.0' },
  { capabilities: { tools: {} } },
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  let result;
  switch (name) {
    case 'send_instruction':
      result = await handleSendInstruction(args);
      break;
    case 'get_status':
      result = await handleGetStatus(args);
      break;
    case 'get_response':
      result = await handleGetResponse(args);
      break;
    case 'wait_for_response':
      result = await handleWaitForResponse(args);
      break;
    case 'wait_for_codex_review':
      result = await handleWaitForCodexReview(args);
      break;
    case 'get_conversation':
      result = await handleGetConversation(args);
      break;
    case 'get_worker_observer':
      result = await handleGetWorkerObserver(args);
      break;
    default:
      throw new Error(`Unknown tool: ${name}`);
  }

  return {
    content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
  };
});

const transport = new StdioServerTransport();
await server.connect(transport);
