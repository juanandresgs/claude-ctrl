#!/usr/bin/env node

import fs from "node:fs";
import process from "node:process";
import path from "node:path";
import { execFileSync, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

import { getCodexLoginStatus } from "./lib/codex.mjs";
import { loadPromptTemplate, interpolateTemplate } from "./lib/prompts.mjs";
import { getConfig, listJobs } from "./lib/state.mjs";
import { sortJobsNewestFirst } from "./lib/job-control.mjs";
import { SESSION_ID_ENV } from "./lib/tracked-jobs.mjs";
import { resolveWorkspaceRoot } from "./lib/workspace.mjs";

const STOP_REVIEW_TIMEOUT_MS = 15 * 60 * 1000;
const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = path.resolve(SCRIPT_DIR, "..");
const STOP_GATE_TITLE = "Codex Stop Gate Review";

// ── Helpers ──────────────────────────────────────────────────────────

function readHookInput() {
  const raw = fs.readFileSync(0, "utf8").trim();
  if (!raw) {
    return {};
  }
  return JSON.parse(raw);
}

function emitDecision(payload) {
  process.stdout.write(`${JSON.stringify(payload)}\n`);
}

function logNote(message) {
  if (!message) {
    return;
  }
  process.stderr.write(`${message}\n`);
}

function filterJobsForCurrentSession(jobs, input = {}) {
  const sessionId = input.session_id || process.env[SESSION_ID_ENV] || null;
  if (!sessionId) {
    return jobs;
  }
  return jobs.filter((job) => job.sessionId === sessionId);
}

// ── Context gathering ────────────────────────────────────────────────

function readFileHead(filePath, maxLines) {
  try {
    const content = fs.readFileSync(filePath, "utf8");
    const lines = content.split("\n");
    if (lines.length <= maxLines) {
      return content;
    }
    return lines.slice(0, maxLines).join("\n") + "\n... (truncated — full file available via file read)";
  } catch {
    return "";
  }
}

function extractInitiativeSummary(filePath) {
  try {
    const content = fs.readFileSync(filePath, "utf8");
    const lines = content.split("\n");
    const summaries = [];
    let i = 0;
    while (i < lines.length) {
      const line = lines[i];
      if (/^### INIT-/.test(line)) {
        if (/\(completed\b/.test(line)) {
          i++;
          continue;
        }
        const block = [line];
        i++;
        while (i < lines.length && !lines[i].startsWith("### ")) {
          const trimmed = lines[i].trimStart();
          if (trimmed.startsWith("- **Status:**") || trimmed.startsWith("- **Goal:**")) {
            block.push(lines[i]);
            i++;
            while (i < lines.length && /^\s{2,}/.test(lines[i]) && !lines[i].trimStart().startsWith("- **")) {
              block.push(lines[i]);
              i++;
            }
          } else {
            i++;
          }
        }
        if (block.length > 1) {
          summaries.push(block.join("\n"));
        }
      } else {
        i++;
      }
    }
    return summaries.length > 0 ? summaries.join("\n\n") : "";
  } catch {
    return "";
  }
}

function getRecentGitLog(cwd) {
  try {
    return execFileSync("git", ["log", "--oneline", "-20"], { cwd, encoding: "utf8", timeout: 5000 }).trim();
  } catch {
    return "";
  }
}

function gatherProjectContext(cwd) {
  const sections = [];
  const planPath = path.join(cwd, "MASTER_PLAN.md");

  const masterPlan = readFileHead(planPath, 77);
  if (masterPlan) {
    sections.push("## MASTER_PLAN.md — Identity, Architecture, Principles\n" + masterPlan);
  }

  const initiatives = extractInitiativeSummary(planPath);
  if (initiatives) {
    sections.push("## Active Initiatives (name, status, goal only)\n" + initiatives);
  }

  return sections.join("\n\n---\n\n") || "No project context files found.";
}

// ── Prompt assembly ──────────────────────────────────────────────────

function buildStopReviewPrompt(cwd, input = {}) {
  const lastAssistantMessage = String(input.last_assistant_message ?? "").trim();
  const template = loadPromptTemplate(ROOT_DIR, "stop-review-gate");
  const claudeResponseBlock = lastAssistantMessage
    ? ["Previous Claude response:", lastAssistantMessage].join("\n")
    : "";
  const projectContext = gatherProjectContext(cwd);
  const gitLog = getRecentGitLog(cwd);
  return interpolateTemplate(template, {
    CLAUDE_RESPONSE_BLOCK: claudeResponseBlock,
    PROJECT_CONTEXT_BLOCK: projectContext || "No project context available.",
    GIT_LOG_BLOCK: gitLog || "No recent git activity."
  });
}

// ── Setup check ──────────────────────────────────────────────────────

function buildSetupNote(cwd) {
  const authStatus = getCodexLoginStatus(cwd);
  if (authStatus.available && authStatus.loggedIn) {
    return null;
  }
  const detail = authStatus.detail ? ` ${authStatus.detail}.` : "";
  return `Codex is not set up for the review gate.${detail} Run /codex:setup and, if needed, !codex login.`;
}

// ── Thread reuse ─────────────────────────────────────────────────────

function findPriorStopGateThread(workspaceRoot, sessionId) {
  if (!sessionId) {
    return null;
  }
  const jobs = sortJobsNewestFirst(listJobs(workspaceRoot));
  const prior = jobs.find(
    (job) =>
      job.title === STOP_GATE_TITLE &&
      job.sessionId === sessionId &&
      job.threadId &&
      job.status !== "queued" &&
      job.status !== "running"
  );
  return prior?.threadId ?? null;
}

// ── Output parser ────────────────────────────────────────────────────

function parseStopReviewOutput(rawOutput) {
  const text = String(rawOutput ?? "").trim();
  if (!text) {
    return {
      ok: false,
      infraFailure: true,
      reason: "Codex review returned no output."
    };
  }

  const lines = text.split(/\r?\n/);

  // Scan from the end for the verdict line
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i].trim();

    if (line.startsWith("VERDICT: PASS") || line.startsWith("VERDICT:PASS")) {
      const findings = lines.slice(0, i).join("\n").trim();
      return { ok: true, reason: findings || null };
    }

    if (line.startsWith("VERDICT: CONTINUE") || line.startsWith("VERDICT:CONTINUE")) {
      const findings = lines.slice(0, i).join("\n").trim();
      const verdictSummary = line.replace(/^VERDICT:\s*CONTINUE[\s—-]*/, "").trim();
      const fullReason = findings
        ? `${findings}\n\nNext: ${verdictSummary}`
        : verdictSummary || text;
      return {
        ok: false,
        reason: `Codex review — work is not yet complete:\n\n${fullReason}`
      };
    }
  }

  // Legacy format fallback
  const firstLine = lines[0].trim();
  if (firstLine.startsWith("ALLOW:")) {
    return { ok: true, reason: null };
  }
  if (firstLine.startsWith("BLOCK:")) {
    return {
      ok: false,
      reason: `Codex review:\n\n${firstLine.slice("BLOCK:".length).trim() || text}`
    };
  }

  // No recognized verdict — treat as infra failure (allow stop with warning)
  return {
    ok: false,
    infraFailure: true,
    reason: `Codex review returned no recognizable verdict. Full output:\n\n${text}`
  };
}

// ── Codex invocation ─────────────────────────────────────────────────

function invokeCodexTask(cwd, args, childEnv, { resuming = false } = {}) {
  const scriptPath = path.join(SCRIPT_DIR, "codex-companion.mjs");

  // Bookend: announce the review start
  logNote(resuming
    ? "[review-gate] Resuming Codex review thread..."
    : "[review-gate] Starting Codex review...");

  // Stream stderr to terminal in real time (progress lines from Codex),
  // capture stdout for JSON result parsing.
  const result = spawnSync(process.execPath, [scriptPath, ...args], {
    cwd,
    env: childEnv,
    encoding: "utf8",
    timeout: STOP_REVIEW_TIMEOUT_MS,
    stdio: ["pipe", "pipe", process.stderr]
  });

  if (result.error?.code === "ETIMEDOUT") {
    logNote("[review-gate] Timed out after 15 minutes.");
    return {
      ok: false,
      infraFailure: true,
      reason: "Codex review timed out after 15 minutes.",
      threadId: null
    };
  }

  if (result.status !== 0) {
    // stderr already streamed to terminal; stdout may have error detail
    const detail = String(result.stdout || "").trim();
    logNote(`[review-gate] Codex process exited with status ${result.status}.`);
    return {
      ok: false,
      infraFailure: true,
      exitDetail: detail,
      threadId: null
    };
  }

  try {
    const payload = JSON.parse(result.stdout);
    const parsed = parseStopReviewOutput(payload?.rawOutput);
    parsed.threadId = payload?.threadId ?? null;

    // Bookend: announce the verdict
    if (parsed.ok) {
      logNote("[review-gate] VERDICT: PASS");
    } else if (parsed.infraFailure) {
      logNote("[review-gate] No recognizable verdict — allowing stop.");
    } else {
      logNote("[review-gate] VERDICT: CONTINUE — findings fed back to Claude.");
    }

    return parsed;
  } catch {
    logNote("[review-gate] Failed to parse Codex output.");
    return {
      ok: false,
      infraFailure: true,
      reason: "Codex review returned invalid JSON.",
      threadId: null
    };
  }
}

// ── SubagentStop verdict emitter ─────────────────────────────────────
//
// Writes a codex_stop_review event to the runtime events table so that
// dispatch_engine._check_codex_gate() can read the verdict and override
// auto_dispatch when BLOCK. This path must NOT emit decision:block to
// hookSpecificOutput — that is reserved for the Stop event path where
// Claude itself is the actor being blocked. At SubagentStop, dispatch_engine
// is the sole auto_dispatch authority; this hook is a pure event emitter.
//
// @decision DEC-AD-002
// Title: Codex gate communicates verdict via events table, not hookSpecificOutput
// Status: accepted
// Rationale: SubagentStop hooks cannot directly mutate dispatch_engine results.
//   Writing to the events table decouples the Codex gate (quality signal) from
//   dispatch_engine (routing authority). post-task.sh reads both; the gate writes
//   only. Errors during emission are suppressed — the gate is advisory.

function emitCodexReviewEventSync(cwd, workflowId, verdict, reason) {
  // Synchronous variant — stops-review hook runs synchronously.
  const cliPath = path.resolve(SCRIPT_DIR, "..", "..", "..", "..", "..", "..", "runtime", "cli.py");
  const detail = `VERDICT: ${verdict} — workflow=${workflowId} | ${reason || "no detail"}`;
  try {
    execFileSync(
      "python3",
      [cliPath, "event", "emit", "codex_stop_review", "--detail", detail],
      { cwd, timeout: 5000, encoding: "utf8" }
    );
  } catch {
    // Advisory; never block routing on event emission errors (DEC-AD-003)
  }
}

function runStopReview(cwd, input = {}) {
  const workspaceRoot = resolveWorkspaceRoot(cwd);
  const sessionId = input.session_id || process.env[SESSION_ID_ENV] || null;
  const prompt = buildStopReviewPrompt(cwd, input);
  const childEnv = {
    ...process.env,
    ...(sessionId ? { [SESSION_ID_ENV]: sessionId } : {})
  };

  // Resume prior stop-gate thread if one exists for this session
  const priorThreadId = findPriorStopGateThread(workspaceRoot, sessionId);

  if (priorThreadId) {
    const result = invokeCodexTask(cwd, ["task", "--json", "--progress", "--resume-thread", priorThreadId, prompt], childEnv, { resuming: true });
    if (result.ok !== undefined && !result.exitDetail) {
      return result;
    }
    // Resume failed — fall through to fresh
    logNote("[review-gate] Prior thread could not be resumed — starting fresh.");
  }

  // Fresh thread
  const result = invokeCodexTask(cwd, ["task", "--json", "--progress", prompt], childEnv);
  if (result.exitDetail) {
    return {
      ok: false,
      infraFailure: true,
      reason: `Codex review failed: ${result.exitDetail}`,
      threadId: null
    };
  }
  return result;
}

// ── Main ─────────────────────────────────────────────────────────────

function main() {
  const input = readHookInput();
  const cwd = input.cwd || process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const workspaceRoot = resolveWorkspaceRoot(cwd);
  const config = getConfig(workspaceRoot);

  // Detect SubagentStop vs Stop: SubagentStop input has agent_type field.
  // When agent_type is present, we are in the SubagentStop hook chain.
  const isSubagentStop = Boolean(input.agent_type);

  const jobs = sortJobsNewestFirst(filterJobsForCurrentSession(listJobs(workspaceRoot), input));
  const runningJob = jobs.find((job) => job.status === "queued" || job.status === "running");
  const runningTaskNote = runningJob
    ? `Codex task ${runningJob.id} is still running. Check /codex:status and use /codex:cancel ${runningJob.id} if you want to stop it before ending the session.`
    : null;

  if (!config.stopReviewGate) {
    if (!isSubagentStop) {
      // On Stop, always log the running task note even when gate is off.
      logNote(runningTaskNote);
    }
    return;
  }

  const setupNote = buildSetupNote(cwd);
  if (setupNote) {
    if (!isSubagentStop) {
      logNote(setupNote);
      logNote(runningTaskNote);
      // Surface to user via additionalContext so it's visible in the session
      emitDecision({ additionalContext: `Review gate: ${setupNote}` });
    }
    return;
  }

  const review = runStopReview(cwd, input);
  const workflowId = input.workflow_id || "";

  if (isSubagentStop) {
    // SubagentStop path: write verdict to events table, emit only informational
    // additionalContext. Do NOT emit decision:block — dispatch_engine owns routing.
    // Infrastructure failures → ALLOW (don't block routing on infra issues).
    const verdict = review.ok || review.infraFailure ? "ALLOW" : "BLOCK";
    const reason = review.infraFailure
      ? `infra failure: ${review.reason}`
      : review.reason || (review.ok ? "work looks good" : "review found issues");
    emitCodexReviewEventSync(cwd, workflowId, verdict, reason);
    // Informational only — orchestrator sees this in additionalContext
    const contextNote = review.ok
      ? `Codex gate (SubagentStop/${input.agent_type}): ALLOW`
      : `Codex gate (SubagentStop/${input.agent_type}): BLOCK — ${reason}`;
    emitDecision({ additionalContext: contextNote });
    return;
  }

  // Stop event path.
  // Infrastructure failures (timeout, process crash, bad JSON) → allow with warning.
  // Review findings (CONTINUE verdict) → block so Claude acts on them.
  if (!review.ok && review.infraFailure) {
    const msg = `Codex review unavailable — allowing stop. ${review.reason}`;
    logNote(msg);
    logNote(runningTaskNote);
    emitDecision({ additionalContext: `Review gate: ${msg}` });
    return;
  }

  if (!review.ok) {
    emitDecision({
      decision: "block",
      reason: runningTaskNote ? `${runningTaskNote}\n\n${review.reason}` : review.reason
    });
    return;
  }

  // PASS — both models agree work is complete
  if (review.reason) {
    logNote(`Codex review (PASS):\n${review.reason}`);
  }
  logNote(runningTaskNote);
}

main();
