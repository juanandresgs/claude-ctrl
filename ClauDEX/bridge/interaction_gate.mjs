import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { pathToFileURL } from 'node:url';

const INTERACTION_GATE_FILENAME = 'interaction-gate.json';

function resolveBraidRoot() {
  if (process.env.BRAID_ROOT) {
    return process.env.BRAID_ROOT;
  }
  const hintPath = join(process.cwd(), '.claude', 'claudex', 'braid-root');
  if (!existsSync(hintPath)) {
    throw new Error(
      'BRAID_ROOT is required, or write the braid root path to .claude/claudex/braid-root.',
    );
  }
  const hinted = readFileSync(hintPath, 'utf8').trim();
  if (!hinted) {
    throw new Error(`${hintPath} is empty; set BRAID_ROOT or write a braid root path.`);
  }
  return hinted;
}

function gateArtifactPath(runDir) {
  return join(runDir, INTERACTION_GATE_FILENAME);
}

function readJSON(path) {
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch {
    return null;
  }
}

function writeJSON(path, obj) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, JSON.stringify(obj, null, 2) + '\n', 'utf8');
}

function readInteractionGate(runDir) {
  return readJSON(gateArtifactPath(runDir));
}

function clearInteractionGate(runDir) {
  try {
    rmSync(gateArtifactPath(runDir), { force: true });
  } catch {
    // Best-effort only.
  }
}

function significantLines(text) {
  return String(text ?? '')
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
}

function firstMatchingLine(text, matcher) {
  return significantLines(text).find((line) => matcher.test(line)) ?? null;
}

function lastMatchingLineIndex(lines, matcher) {
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    if (matcher.test(lines[i])) {
      return i;
    }
  }
  return -1;
}

function extractNumberedChoices(text) {
  return significantLines(text)
    .filter((line) => /^(?:[>*>❯]\s*)?\d+\.\s+/.test(line))
    .map((line) => {
      const match = line.match(/^(?:[>*>❯]\s*)?(\d+)\.\s+(.*)$/);
      return match ? { choice: match[1], label: match[2] } : null;
    })
    .filter(Boolean);
}

function extractSelectedChoice(text) {
  const line = firstMatchingLine(text, /^[>*>❯]\s*\d+\.\s+/);
  const match = line?.match(/^[>*>❯]\s*(\d+)\.\s+/);
  return match ? match[1] : null;
}

function extractYesNoChoices(text) {
  const lines = significantLines(text);
  if (!lines.some((line) => /\byes\b/i.test(line)) || !lines.some((line) => /\bno\b/i.test(line))) {
    return [];
  }
  return [
    { choice: 'y', label: 'Yes' },
    { choice: 'n', label: 'No' },
  ];
}

function fingerprintForGate({ gate_type, prompt_excerpt, instruction_id, tmux_target }) {
  return createHash('sha1')
    .update([
      gate_type ?? '',
      prompt_excerpt ?? '',
      instruction_id ?? '',
      tmux_target ?? '',
    ].join('|'))
    .digest('hex');
}

function detectInteractionGate(text, classification = 'unknown') {
  if (!text || typeof text !== 'string') return null;

  const lines = significantLines(text);
  const numberedChoices = extractNumberedChoices(text);
  const yesNoChoices = extractYesNoChoices(text);
  const gateChoices = numberedChoices.length > 0 ? numberedChoices : yesNoChoices;
  const selectedChoice = extractSelectedChoice(text);

  const trustLine = firstMatchingLine(text, /Do you trust the contents of this directory\?/i);
  if (trustLine) {
    return {
      gate_type: 'trust_prompt',
      prompt_excerpt: trustLine,
      choices: gateChoices,
      selected_choice: selectedChoice,
      resolution_hint: 'Send the numeric choice shown by the harness.',
    };
  }

  const editLine = firstMatchingLine(text, /Do you want to make this edit(?:\s+to\s+.+?)?\?/i);
  if (editLine) {
    const targetLine = firstMatchingLine(text, /File must be read first|edit its own settings/i);
    return {
      gate_type: 'edit_approval',
      prompt_excerpt: editLine,
      prompt_target: targetLine,
      choices: gateChoices,
      selected_choice: selectedChoice,
      resolution_hint: 'Send the numeric choice shown by the harness.',
    };
  }

  const settingsLine = firstMatchingLine(text, /allow .* to edit .* settings .* session/i);
  if (settingsLine) {
    return {
      gate_type: 'settings_approval',
      prompt_excerpt: settingsLine,
      choices: gateChoices,
      selected_choice: selectedChoice,
      resolution_hint: 'Send the numeric choice shown by the harness.',
    };
  }

  const apiErrorIndex = lastMatchingLineIndex(lines, /API Error:/i);
  if (apiErrorIndex >= 0) {
    const trailingLines = lines.slice(apiErrorIndex + 1);
    const substantiveTrailingLines = trailingLines.filter((line) => !(
      /^(?:[>*>❯]\s*)?$/.test(line)
      || /^✻\s+Brewed for\b/i.test(line)
      || /^⏵⏵\s+bypass permissions\b/i.test(line)
      || /^__BRAID_RELAY__$/.test(line)
      || /^Press up to edit queued messages$/i.test(line)
    ));
    if (substantiveTrailingLines.length > 0) {
      return null;
    }
    const apiErrorLine = lines[apiErrorIndex];
    const gateType = /overloaded_error|rate[_ -]?limit|429|temporar(?:ily)? unavailable/i.test(apiErrorLine)
      ? 'provider_overload'
      : 'provider_error';
    return {
      gate_type: gateType,
      prompt_excerpt: apiErrorLine,
      choices: [],
      selected_choice: null,
      resolution_hint: 'No harness choice is available. Supervisor should inspect and retry or requeue the bounded slice.',
    };
  }

  if (classification === 'permission_prompt') {
    // Claude's normal footer includes this exact line even when no approval
    // gate is open. The footer can coexist with normal worker output, so
    // ignore it here and let the explicit trust/edit/settings matchers above
    // handle real gates.
    if (lines.some((line) => /bypass permissions on \(shift\+tab to cycle\)/i.test(line))) {
      return null;
    }

    const promptLine =
      firstMatchingLine(text, /(allow|approve|permission|deny|continue)/i)
      ?? lines.at(-1)
      ?? 'permission prompt';
    return {
      gate_type: 'permission_prompt',
      prompt_excerpt: promptLine,
      choices: gateChoices,
      selected_choice: selectedChoice,
      resolution_hint: gateChoices.length > 0
        ? 'Send the choice shown by the harness.'
        : 'Send the harness-specific approval response.',
    };
  }

  return null;
}

function buildInteractionGate({
  run_id,
  bridge_state,
  instruction_id = null,
  session_id = null,
  tmux_target,
  text,
  classification,
  now = new Date().toISOString(),
  existing = null,
}) {
  const detected = detectInteractionGate(text, classification);
  if (!detected) return null;

  const fingerprint = fingerprintForGate({
    ...detected,
    instruction_id,
    tmux_target,
  });
  const openedAt = existing?.fingerprint === fingerprint ? existing.opened_at : now;

  return {
    gate_id: existing?.fingerprint === fingerprint ? existing.gate_id : fingerprint,
    fingerprint,
    status: 'open',
    run_id,
    bridge_state,
    instruction_id,
    session_id,
    tmux_target,
    classification,
    ...detected,
    opened_at: openedAt,
    updated_at: now,
  };
}

function buildInteractionGateReview(gate) {
  if (!gate) return null;
  const target = gate.prompt_target ? ` Target: ${gate.prompt_target}.` : '';
  const choices = Array.isArray(gate.choices) && gate.choices.length > 0
    ? ` Choices: ${gate.choices.map((entry) => `${entry.choice}=${entry.label}`).join(', ')}.`
    : '';
  const selected = gate.selected_choice ? ` Current selection: ${gate.selected_choice}.` : '';
  return {
    instruction_id: gate.instruction_id ?? null,
    gate_id: gate.gate_id ?? null,
    gate_type: gate.gate_type ?? 'interaction_gate',
    response: `Worker blocked on interaction gate (${gate.gate_type}) in ${gate.tmux_target}. Prompt: ${gate.prompt_excerpt}.${target}${choices}${selected} ${gate.resolution_hint ?? ''}`.trim(),
    interaction_gate: gate,
  };
}

function buildResolutionKeySequence(gate, choice) {
  const normalizedChoice = String(choice ?? '').trim();
  const selectedChoice = String(gate?.selected_choice ?? '').trim();
  if (!normalizedChoice) {
    throw new Error('choice is required');
  }

  if (
    /^\d+$/.test(normalizedChoice)
    && /^\d+$/.test(selectedChoice)
  ) {
    const delta = Number(normalizedChoice) - Number(selectedChoice);
    if (delta === 0) {
      return ['Enter'];
    }
    if (delta > 0) {
      return [...Array.from({ length: delta }, () => 'Down'), 'Enter'];
    }
    return [...Array.from({ length: Math.abs(delta) }, () => 'Up'), 'Enter'];
  }

  return [normalizedChoice, 'Enter'];
}

function capturePaneText(tmuxTarget) {
  return execFileSync(
    'tmux',
    ['capture-pane', '-pt', tmuxTarget],
    { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'], timeout: 5000 },
  );
}

async function loadObserverHelpers() {
  const moduleUrl = pathToFileURL(join(resolveBraidRoot(), 'lib/observer.mjs')).href;
  return import(moduleUrl);
}

async function captureInteractionGate({
  runDir,
  runId,
  bridgeState,
  instructionId = null,
  sessionId = null,
  tmuxTarget,
}) {
  const text = capturePaneText(tmuxTarget);
  let classification = 'unknown';

  try {
    const observer = await loadObserverHelpers();
    classification = observer.classifyWorkerState(text);
    observer.captureSnapshotFromText(runDir, text, 'watchdog_gate_poll', tmuxTarget);
  } catch {
    // Observer artifacts are helpful but not required for gate detection.
  }

  const existing = readInteractionGate(runDir);
  const gate = buildInteractionGate({
    run_id: runId,
    bridge_state: bridgeState,
    instruction_id: instructionId,
    session_id: sessionId,
    tmux_target: tmuxTarget,
    text,
    classification,
    existing,
  });

  if (!gate) {
    clearInteractionGate(runDir);
    return { status: 'no_gate', classification, gate: null };
  }

  writeJSON(gateArtifactPath(runDir), gate);
  return { status: 'gate_open', classification, gate };
}

async function resolveInteractionGate({
  runDir,
  tmuxTarget,
  choice,
}) {
  const existingGate = readInteractionGate(runDir);
  const beforeText = capturePaneText(tmuxTarget);
  let classification = 'unknown';
  try {
    const observer = await loadObserverHelpers();
    classification = observer.classifyWorkerState(beforeText);
  } catch {
    // Continue with local gate detection only.
  }

  const currentGate = buildInteractionGate({
    run_id: existingGate?.run_id ?? null,
    bridge_state: existingGate?.bridge_state ?? null,
    instruction_id: existingGate?.instruction_id ?? null,
    session_id: existingGate?.session_id ?? null,
    tmux_target: tmuxTarget,
    text: beforeText,
    classification,
    existing: existingGate,
  });

  if (!currentGate) {
    return { status: 'no_gate', gate: null };
  }

  if (existingGate?.fingerprint && existingGate.fingerprint !== currentGate.fingerprint) {
    return {
      status: 'gate_mismatch',
      expected_gate: existingGate,
      current_gate: currentGate,
    };
  }

  const keySequence = buildResolutionKeySequence(currentGate, choice);

  execFileSync(
    'tmux',
    ['send-keys', '-t', tmuxTarget, ...keySequence],
    { stdio: ['pipe', 'pipe', 'pipe'], timeout: 5000 },
  );

  await new Promise((resolve) => setTimeout(resolve, 150));
  const afterText = capturePaneText(tmuxTarget);
  let afterClassification = 'unknown';
  try {
    const observer = await loadObserverHelpers();
    afterClassification = observer.classifyWorkerState(afterText);
    observer.captureSnapshotFromText(runDir, afterText, 'gate_resolve', tmuxTarget);
  } catch {
    // Best-effort only.
  }

  const afterGate = buildInteractionGate({
    run_id: null,
    bridge_state: null,
    instruction_id: null,
    session_id: null,
    tmux_target: tmuxTarget,
    text: afterText,
    classification: afterClassification,
    existing: readInteractionGate(runDir),
  });

  if (!afterGate) {
    clearInteractionGate(runDir);
    return {
      status: 'resolved',
      choice,
      previous_gate: currentGate,
    };
  }

  writeJSON(gateArtifactPath(runDir), afterGate);
  return {
    status: 'still_open',
    choice,
    previous_gate: currentGate,
    current_gate: afterGate,
  };
}

function parseArgs(argv) {
  const [command, ...rest] = argv;
  const args = { command };
  for (let i = 0; i < rest.length; i += 1) {
    const token = rest[i];
    if (!token.startsWith('--')) continue;
    const key = token.slice(2).replace(/-/g, '_');
    const next = rest[i + 1];
    if (!next || next.startsWith('--')) {
      args[key] = true;
      continue;
    }
    args[key] = next;
    i += 1;
  }
  return args;
}

async function main(argv = process.argv.slice(2)) {
  const args = parseArgs(argv);
  if (!args.command) {
    throw new Error('Expected a subcommand: capture | status | resolve');
  }

  if (args.command === 'capture') {
    if (!args.run_dir || !args.run_id || !args.tmux_target) {
      throw new Error('capture requires --run-dir, --run-id, and --tmux-target');
    }
    const result = await captureInteractionGate({
      runDir: args.run_dir,
      runId: args.run_id,
      bridgeState: args.bridge_state ?? null,
      instructionId: args.instruction_id ?? null,
      sessionId: args.session_id ?? null,
      tmuxTarget: args.tmux_target,
    });
    process.stdout.write(JSON.stringify(result) + '\n');
    return;
  }

  if (args.command === 'status') {
    if (!args.run_dir) {
      throw new Error('status requires --run-dir');
    }
    process.stdout.write(JSON.stringify(readInteractionGate(args.run_dir)) + '\n');
    return;
  }

  if (args.command === 'resolve') {
    if (!args.run_dir || !args.tmux_target || !args.choice) {
      throw new Error('resolve requires --run-dir, --tmux-target, and --choice');
    }
    const result = await resolveInteractionGate({
      runDir: args.run_dir,
      tmuxTarget: args.tmux_target,
      choice: args.choice,
    });
    process.stdout.write(JSON.stringify(result) + '\n');
    return;
  }

  throw new Error(`Unknown subcommand: ${args.command}`);
}

export {
  INTERACTION_GATE_FILENAME,
  gateArtifactPath,
  readInteractionGate,
  clearInteractionGate,
  detectInteractionGate,
  buildInteractionGate,
  buildInteractionGateReview,
  buildResolutionKeySequence,
  captureInteractionGate,
  resolveInteractionGate,
};

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  main().catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exit(1);
  });
}
