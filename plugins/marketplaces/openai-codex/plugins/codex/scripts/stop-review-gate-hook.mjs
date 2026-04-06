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
const POLICY_DIR = path.resolve(ROOT_DIR, "policies");
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

// ── Availability checks ─────────────────────────────────────────────

function isCodexReady(cwd) {
  const status = getCodexLoginStatus(cwd);
  return status.available && status.loggedIn;
}

function isGeminiReady() {
  try {
    const result = spawnSync("gemini", ["--version"], { encoding: "utf8", timeout: 5000 });
    if (result.status !== 0) {
      return false;
    }
    // Check OAuth creds exist
    const home = process.env.HOME || process.env.USERPROFILE || "";
    const credsPath = path.join(home, ".gemini", "oauth_creds.json");
    return fs.existsSync(credsPath);
  } catch {
    return false;
  }
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

// Gemini session-id persistence: stored per-session in the plugin state dir.
function getGeminiSessionFile(workspaceRoot, sessionId) {
  const stateDir = path.join(workspaceRoot, ".codex-plugin-state");
  return path.join(stateDir, `gemini-stop-gate-${sessionId}.json`);
}

function findPriorGeminiSession(workspaceRoot, sessionId) {
  if (!sessionId) {
    return null;
  }
  try {
    const filePath = getGeminiSessionFile(workspaceRoot, sessionId);
    const data = JSON.parse(fs.readFileSync(filePath, "utf8"));
    return data.geminiSessionId ?? null;
  } catch {
    return null;
  }
}

function savePriorGeminiSession(workspaceRoot, sessionId, geminiSessionId) {
  if (!sessionId || !geminiSessionId) {
    return;
  }
  try {
    const filePath = getGeminiSessionFile(workspaceRoot, sessionId);
    const dir = path.dirname(filePath);
    if (!fs.existsSync(dir)) {
      fs.mkdirSync(dir, { recursive: true });
    }
    fs.writeFileSync(filePath, JSON.stringify({ geminiSessionId, updatedAt: new Date().toISOString() }));
  } catch {
    // Best effort
  }
}

// ── Output parser ────────────────────────────────────────────────────

function parseStopReviewOutput(rawOutput) {
  const text = String(rawOutput ?? "").trim();
  if (!text) {
    return {
      ok: false,
      infraFailure: true,
      reason: "Review returned no output."
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
        reason: `Review — work is not yet complete:\n\n${fullReason}`
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
      reason: `Review:\n\n${firstLine.slice("BLOCK:".length).trim() || text}`
    };
  }

  // No recognized verdict — treat as infra failure (allow stop with warning)
  return {
    ok: false,
    infraFailure: true,
    reason: `Review returned no recognizable verdict. Full output:\n\n${text}`
  };
}

// ── Codex invocation ─────────────────────────────────────────────────

function invokeCodexTask(cwd, args, childEnv, { resuming = false } = {}) {
  const scriptPath = path.join(SCRIPT_DIR, "codex-companion.mjs");

  logNote(resuming
    ? "[review-gate:codex] Resuming review thread..."
    : "[review-gate:codex] Starting review...");

  const result = spawnSync(process.execPath, [scriptPath, ...args], {
    cwd,
    env: childEnv,
    encoding: "utf8",
    timeout: STOP_REVIEW_TIMEOUT_MS,
    stdio: ["pipe", "pipe", process.stderr]
  });

  if (result.error?.code === "ETIMEDOUT") {
    logNote("[review-gate:codex] Timed out.");
    return { ok: false, infraFailure: true, reason: "Codex review timed out.", threadId: null };
  }

  if (result.status !== 0) {
    const detail = String(result.stdout || "").trim();
    logNote(`[review-gate:codex] Process exited with status ${result.status}.`);
    return { ok: false, infraFailure: true, exitDetail: detail, threadId: null };
  }

  try {
    const payload = JSON.parse(result.stdout);
    const parsed = parseStopReviewOutput(payload?.rawOutput);
    parsed.threadId = payload?.threadId ?? null;
    parsed.provider = "codex";

    if (parsed.ok) {
      logNote("[review-gate:codex] VERDICT: PASS");
    } else if (parsed.infraFailure) {
      logNote("[review-gate:codex] No recognizable verdict.");
    } else {
      logNote("[review-gate:codex] VERDICT: CONTINUE");
    }

    return parsed;
  } catch {
    logNote("[review-gate:codex] Failed to parse output.");
    return { ok: false, infraFailure: true, reason: "Codex returned invalid JSON.", threadId: null };
  }
}

function runCodexReview(cwd, input = {}) {
  const workspaceRoot = resolveWorkspaceRoot(cwd);
  const sessionId = input.session_id || process.env[SESSION_ID_ENV] || null;
  const prompt = buildStopReviewPrompt(cwd, input);
  const childEnv = {
    ...process.env,
    ...(sessionId ? { [SESSION_ID_ENV]: sessionId } : {})
  };

  const priorThreadId = findPriorStopGateThread(workspaceRoot, sessionId);

  if (priorThreadId) {
    const result = invokeCodexTask(cwd, ["task", "--json", "--progress", "--resume-thread", priorThreadId, prompt], childEnv, { resuming: true });
    if (result.ok !== undefined && !result.exitDetail) {
      return result;
    }
    logNote("[review-gate:codex] Prior thread could not be resumed — starting fresh.");
  }

  const result = invokeCodexTask(cwd, ["task", "--json", "--progress", prompt], childEnv);
  if (result.exitDetail) {
    return { ok: false, infraFailure: true, reason: `Codex review failed: ${result.exitDetail}`, threadId: null };
  }
  return result;
}

// ── Gemini invocation ────────────────────────────────────────────────

function invokeGeminiTask(cwd, prompt, { resumeSessionId = null } = {}) {
  logNote(resumeSessionId
    ? `[review-gate:gemini] Resuming session ${resumeSessionId.slice(0, 8)}...`
    : "[review-gate:gemini] Starting review...");

  const policyPath = path.join(POLICY_DIR, "stop-gate-readonly.toml");
  const args = [
    "-p", prompt,
    "--approval-mode", "plan",
    "--output-format", "json",
    "--yolo"  // suppress interactive confirmation for allowed tools
  ];

  // Add policy if it exists
  if (fs.existsSync(policyPath)) {
    args.push("--policy", policyPath);
  }

  // Resume prior session
  if (resumeSessionId) {
    args.push("--resume", resumeSessionId);
  }

  const result = spawnSync("gemini", args, {
    cwd,
    encoding: "utf8",
    timeout: STOP_REVIEW_TIMEOUT_MS,
    stdio: ["pipe", "pipe", process.stderr]
  });

  if (result.error?.code === "ETIMEDOUT") {
    logNote("[review-gate:gemini] Timed out.");
    return { ok: false, infraFailure: true, reason: "Gemini review timed out.", geminiSessionId: null };
  }

  if (result.status !== 0) {
    logNote(`[review-gate:gemini] Process exited with status ${result.status}.`);
    return { ok: false, infraFailure: true, reason: "Gemini review process failed.", geminiSessionId: null };
  }

  try {
    const payload = JSON.parse(result.stdout);
    const parsed = parseStopReviewOutput(payload?.response);
    parsed.geminiSessionId = payload?.session_id ?? null;
    parsed.provider = "gemini";

    if (parsed.ok) {
      logNote("[review-gate:gemini] VERDICT: PASS");
    } else if (parsed.infraFailure) {
      logNote("[review-gate:gemini] No recognizable verdict.");
    } else {
      logNote("[review-gate:gemini] VERDICT: CONTINUE");
    }

    return parsed;
  } catch {
    logNote("[review-gate:gemini] Failed to parse output.");
    return { ok: false, infraFailure: true, reason: "Gemini returned invalid JSON.", geminiSessionId: null };
  }
}

function runGeminiReview(cwd, input = {}) {
  const workspaceRoot = resolveWorkspaceRoot(cwd);
  const sessionId = input.session_id || process.env[SESSION_ID_ENV] || null;
  const prompt = buildStopReviewPrompt(cwd, input);

  const priorGeminiSession = findPriorGeminiSession(workspaceRoot, sessionId);

  if (priorGeminiSession) {
    const result = invokeGeminiTask(cwd, prompt, { resumeSessionId: priorGeminiSession });
    if (result.ok !== undefined && !result.infraFailure) {
      if (result.geminiSessionId) {
        savePriorGeminiSession(workspaceRoot, sessionId, result.geminiSessionId);
      }
      return result;
    }
    logNote("[review-gate:gemini] Prior session could not be resumed — starting fresh.");
  }

  const result = invokeGeminiTask(cwd, prompt);
  if (result.geminiSessionId) {
    savePriorGeminiSession(workspaceRoot, sessionId, result.geminiSessionId);
  }
  return result;
}

// ── Review orchestrator (Codex → Gemini → allow) ────────────────────

function runStopReview(cwd, input = {}) {
  const codexReady = isCodexReady(cwd);
  const geminiReady = isGeminiReady();

  if (!codexReady && !geminiReady) {
    logNote("[review-gate] Neither Codex nor Gemini available.");
    return {
      ok: false,
      infraFailure: true,
      reason: "No reviewer available (Codex and Gemini both unavailable)."
    };
  }

  // Primary: Codex
  if (codexReady) {
    const result = runCodexReview(cwd, input);
    if (!result.infraFailure) {
      return result;
    }
    logNote("[review-gate] Codex failed — trying Gemini fallback...");
  }

  // Fallback: Gemini
  if (geminiReady) {
    return runGeminiReview(cwd, input);
  }

  // Should not reach here, but handle gracefully
  return {
    ok: false,
    infraFailure: true,
    reason: "No reviewer could complete the review."
  };
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

// ── Main ─────────────────────────────────────────────────────────────

function main() {
  const input = readHookInput();
  const cwd = input.cwd || process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const workspaceRoot = resolveWorkspaceRoot(cwd);
  const config = getConfig(workspaceRoot);

  const isSubagentStop = Boolean(input.agent_type);

  const jobs = sortJobsNewestFirst(filterJobsForCurrentSession(listJobs(workspaceRoot), input));
  const runningJob = jobs.find((job) => job.status === "queued" || job.status === "running");
  const runningTaskNote = runningJob
    ? `Codex task ${runningJob.id} is still running. Check /codex:status and use /codex:cancel ${runningJob.id} if you want to stop it before ending the session.`
    : null;

  if (!config.stopReviewGate) {
    if (!isSubagentStop) {
      logNote(runningTaskNote);
    }
    return;
  }

  // Skip setup check — runStopReview handles provider availability internally.

  const review = runStopReview(cwd, input);
  const workflowId = input.workflow_id || "";

  if (isSubagentStop) {
    const verdict = review.ok || review.infraFailure ? "ALLOW" : "BLOCK";
    const reason = review.infraFailure
      ? `infra failure: ${review.reason}`
      : review.reason || (review.ok ? "work looks good" : "review found issues");
    emitCodexReviewEventSync(cwd, workflowId, verdict, reason);
    const provider = review.provider || "unknown";
    const contextNote = review.ok
      ? `Review gate (${provider}, SubagentStop/${input.agent_type}): ALLOW`
      : `Review gate (${provider}, SubagentStop/${input.agent_type}): BLOCK — ${reason}`;
    emitDecision({ additionalContext: contextNote });
    return;
  }

  // Infrastructure failures → allow with warning
  if (!review.ok && review.infraFailure) {
    const msg = `Review gate unavailable — allowing stop. ${review.reason}`;
    logNote(msg);
    logNote(runningTaskNote);
    emitDecision({ additionalContext: `Review gate: ${msg}` });
    return;
  }

  // CONTINUE → block, feed findings to Claude
  if (!review.ok) {
    const provider = review.provider || "reviewer";
    emitDecision({
      decision: "block",
      reason: runningTaskNote
        ? `${runningTaskNote}\n\n[${provider}] ${review.reason}`
        : `[${provider}] ${review.reason}`
    });
    return;
  }

  // PASS — both models agree
  if (review.reason) {
    logNote(`Review gate (${review.provider || "reviewer"}) PASS:\n${review.reason}`);
  }
  logNote(runningTaskNote);
}

main();
