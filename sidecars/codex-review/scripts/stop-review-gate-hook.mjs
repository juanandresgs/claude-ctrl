#!/usr/bin/env node

import fs from "node:fs";
import process from "node:process";
import path from "node:path";
import { execFileSync, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

import { getCodexLoginStatus } from "./lib/codex.mjs";
import { loadPromptTemplate, interpolateTemplate } from "./lib/prompts.mjs";
import { listJobs } from "./lib/state.mjs";
import { sortJobsNewestFirst } from "./lib/job-control.mjs";
import { SESSION_ID_ENV } from "./lib/tracked-jobs.mjs";
import { resolveWorkspaceRoot } from "./lib/workspace.mjs";

const STOP_REVIEW_TIMEOUT_MS = 15 * 60 * 1000;
const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = path.resolve(SCRIPT_DIR, "..");
const REPO_ROOT = path.resolve(ROOT_DIR, "../..");
const RUNTIME_CLI_PATH =
  process.env.CLAUDE_RUNTIME_CLI || path.resolve(REPO_ROOT, "runtime/cli.py");
const POLICY_DIR = path.resolve(ROOT_DIR, "policies");
const STOP_GATE_TITLE = "Codex Stop Gate Review";
const VALID_REVIEW_PROVIDERS = new Set(["auto", "codex", "gemini", "reviewer-subagent"]);

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

function getDiffStat(cwd) {
  try {
    // Include both tracked changes and untracked files
    const tracked = execFileSync("git", ["diff", "--stat", "HEAD"], { cwd, encoding: "utf8", timeout: 5000 }).trim();
    const untracked = execFileSync("git", ["ls-files", "--others", "--exclude-standard"], { cwd, encoding: "utf8", timeout: 5000 }).trim();
    const parts = [];
    if (tracked) parts.push(tracked);
    if (untracked) parts.push(`Untracked files:\n${untracked}`);
    return parts.join("\n\n") || "";
  } catch {
    return "";
  }
}

function getChangedFileCount(cwd) {
  try {
    // Use git status --porcelain to count ALL changes (tracked + untracked)
    const output = execFileSync("git", ["status", "--porcelain"], { cwd, encoding: "utf8", timeout: 5000 }).trim();
    return output ? output.split("\n").length : 0;
  } catch {
    return 0;
  }
}

function buildScopeHint(changedFiles) {
  // NOTE: This counts ALL dirty files in the worktree, not just the ones
  // Claude changed in the current turn. Use git log and Claude's response
  // to identify which files are relevant to the task being reviewed.
  if (changedFiles === 0) {
    return "No uncommitted changes detected. This may be a non-edit turn.";
  }
  if (changedFiles <= 5) {
    return `Worktree has ${changedFiles} dirty files. Full review appropriate. Verify which files Claude actually changed this turn.`;
  }
  if (changedFiles < 15) {
    return `Worktree has ${changedFiles} dirty files (some may predate this turn). Focus on files mentioned in Claude's response and their integration surfaces.`;
  }
  return `Worktree has ${changedFiles} dirty files (likely includes pre-existing changes). Prioritize: (1) files Claude mentions, (2) architectural alignment, (3) test gaps. Skip cosmetic issues. If taking too long, issue verdict based on what you've verified — partial verification with disclosed gaps is better than timeout.`;
}

function buildStopReviewPrompt(cwd, input = {}) {
  const lastAssistantMessage = String(input.last_assistant_message ?? "").trim();
  const template = loadPromptTemplate(ROOT_DIR, "stop-review-gate");
  const claudeResponseBlock = lastAssistantMessage
    ? ["Previous Claude response:", lastAssistantMessage].join("\n")
    : "";
  const projectContext = gatherProjectContext(cwd);
  const gitLog = getRecentGitLog(cwd);
  const diffStat = getDiffStat(cwd);
  const changedFiles = getChangedFileCount(cwd);
  const scopeHint = buildScopeHint(changedFiles);

  return interpolateTemplate(template, {
    CLAUDE_RESPONSE_BLOCK: claudeResponseBlock,
    PROJECT_CONTEXT_BLOCK: projectContext || "No project context available.",
    GIT_LOG_BLOCK: gitLog || "No recent git activity.",
    DIFF_STAT_BLOCK: diffStat || "No diff available.",
    SCOPE_HINT: scopeHint
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

function normalizeReviewProvider(value) {
  const normalized = String(value || "").trim().toLowerCase().replace(/_/g, "-");
  if (!normalized) {
    return "codex";
  }
  if (normalized === "reviewer" || normalized === "reviewer-subagent-fallback") {
    return "reviewer-subagent";
  }
  return VALID_REVIEW_PROVIDERS.has(normalized) ? normalized : "codex";
}

function providerOrder(provider) {
  switch (normalizeReviewProvider(provider)) {
    case "auto":
    case "codex":
      return ["codex", "gemini"];
    case "gemini":
      return ["gemini", "codex"];
    case "reviewer-subagent":
      return [];
    default:
      return ["codex", "gemini"];
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
    "--output-format", "json"
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

// ── Review orchestrator (Codex/Gemini → reviewer subagent fallback) ──

function reportProviderStatus(codexReady, geminiReady, configuredProvider) {
  const status = [];
  status.push(`preference: ${configuredProvider}`);
  status.push(`codex: ${codexReady ? "ready" : "unavailable"}`);
  status.push(`gemini: ${geminiReady ? "ready" : "unavailable"}`);
  logNote(`[review-gate] Providers: ${status.join(", ")}`);
}

function buildReviewerSubagentFallback(reason, configuredProvider, codexReady, geminiReady) {
  return {
    ok: false,
    infraFailure: false,
    provider: "reviewer-subagent",
    reason: [
      "REVIEW_SUBAGENT_REQUIRED: external CLI review could not run.",
      `Configured provider: ${configuredProvider}.`,
      `Codex ready: ${codexReady ? "yes" : "no"}. Gemini ready: ${geminiReady ? "yes" : "no"}.`,
      reason,
      "",
      "Dispatch the canonical reviewer subagent in read-only mode with the current task, changed files, test evidence, and this stop-hook output. Do not end the session until that reviewer returns PASS/CONTINUE guidance."
    ].filter(Boolean).join("\n")
  };
}

function readReviewProvider(cwd, workflowId = "") {
  const envOverride = process.env.CLAUDEX_STOP_REVIEW_PROVIDER || process.env.CLAUDEX_REVIEW_PROVIDER || "";
  if (envOverride) {
    return normalizeReviewProvider(envOverride);
  }
  return normalizeReviewProvider(readEnforcementConfig(cwd, "review_gate_provider", workflowId) || "codex");
}

function runStopReview(cwd, input = {}, workflowId = "") {
  const testReview = resolveTestStopReview();
  if (testReview) {
    logNote("[review-gate:test] Using deterministic stop review test response.");
    return testReview;
  }

  const configuredProvider = readReviewProvider(cwd, workflowId);
  const codexReady = isCodexReady(cwd);
  const geminiReady = isGeminiReady();

  reportProviderStatus(codexReady, geminiReady, configuredProvider);

  if (configuredProvider === "reviewer-subagent") {
    return buildReviewerSubagentFallback(
      "Provider preference explicitly requested reviewer-subagent fallback.",
      configuredProvider,
      codexReady,
      geminiReady
    );
  }

  for (const provider of providerOrder(configuredProvider)) {
    if (provider === "codex") {
      if (!codexReady) {
        logNote("[review-gate] Codex unavailable; checking next provider.");
        continue;
      }
      const result = runCodexReview(cwd, input);
      if (!result.infraFailure) {
        return result;
      }
      logNote(`[review-gate] Codex failed: ${result.reason || result.exitDetail || "unknown error"}`);
      continue;
    }

    if (provider === "gemini") {
      if (!geminiReady) {
        logNote("[review-gate] Gemini unavailable; checking next provider.");
        continue;
      }
      const result = runGeminiReview(cwd, input);
      if (!result.infraFailure) {
        return result;
      }
      logNote(`[review-gate] Gemini failed: ${result.reason || "unknown error"}`);
      if (result.reason && /quota|capacity|rate.limit|429/i.test(result.reason)) {
        logNote("[review-gate] Gemini quota exhausted. Consider upgrading to API key billing or waiting for quota reset.");
      }
    }
  }

  return buildReviewerSubagentFallback(
    "No configured CLI review provider completed the review.",
    configuredProvider,
    codexReady,
    geminiReady
  );
}

function resolveTestStopReview() {
  const raw = process.env.CLAUDEX_STOP_REVIEW_TEST_RESPONSE;
  if (!raw) {
    return null;
  }
  const parsed = parseStopReviewOutput(raw);
  return {
    ...parsed,
    provider: "codex",
    threadId: null
  };
}

function buildPolicyEnv(cwd) {
  const env = { ...process.env };
  const workspaceRoot = resolveWorkspaceRoot(cwd);
  if (!env.CLAUDE_PROJECT_DIR) {
    env.CLAUDE_PROJECT_DIR = workspaceRoot;
  }
  if (!env.CLAUDE_POLICY_DB) {
    env.CLAUDE_POLICY_DB = path.join(env.CLAUDE_PROJECT_DIR, ".claude", "state.db");
  }
  return env;
}

function resolveWorkflowId(cwd, input = {}) {
  const direct = input.workflow_id || input.workflowId;
  if (direct) {
    return String(direct);
  }
  try {
    const out = execFileSync(
      "python3",
      [RUNTIME_CLI_PATH, "context", "role"],
      { cwd, env: buildPolicyEnv(cwd), encoding: "utf8", stdio: ["pipe", "pipe", "pipe"], timeout: 5000 }
    );
    const parsed = JSON.parse(out);
    return String(parsed.workflow_id || "");
  } catch {
    return "";
  }
}

// ── Stop verdict emitter ─────────────────────────────────────────────
//
// Writes a codex_stop_review event to the runtime events table for user-facing
// review observability. The dispatch engine does NOT read these events —
// workflow auto_dispatch is determined by runtime workflow facts only
// (DEC-PHASE5-STOP-REVIEW-SEPARATION-001).
//
// @decision DEC-AD-002
// Title: Codex Stop audit communicates visibility via events table
// Status: accepted
// Rationale: Writing to the events table decouples the Codex Stop audit
//   (quality signal) from dispatch_engine (routing authority). Errors during
//   emission are suppressed — review visibility must not become a routing
//   authority.

// readEnforcementConfig — read a toggle from the policy engine DB.
//
// @decision DEC-CONFIG-AUTHORITY-001
// Title: Policy engine is the canonical authority for enforcement toggles
// Status: accepted
// Rationale: Plugin state.json's stopReviewGate is no longer the authority
//   for whether the regular-Stop review gate runs. The regular-Stop path reads
//   from enforcement_config via cc-policy, making the policy engine the single
//   source of truth. The state.json field is kept as a dual-write target during
//   the deprecation window only.
//
// CRITICAL: mirror the bash cc_policy() pattern of setting CLAUDE_POLICY_DB
// from CLAUDE_PROJECT_DIR before shelling out. Without this, node code
// bypasses project scoping and reads from the default DB path.
// (DEC-CONFIG-AUTHORITY-001 risk #3)
function readEnforcementConfig(cwd, key, workflowId = "") {
  const env = buildPolicyEnv(cwd);
  try {
    const args = [RUNTIME_CLI_PATH, "config", "get", key];
    if (workflowId) {
      args.push("--workflow-id", workflowId);
    }
    args.push("--project-root", cwd);
    const out = execFileSync(
      "python3",
      args,
      { env, encoding: "utf8", stdio: ["pipe", "pipe", "pipe"], timeout: 5000 }
    );
    const parsed = JSON.parse(out);
    return parsed.value || null;
  } catch {
    // Fail-closed: return null, NOT a default-true assumption.
    // Callers must treat null as "unknown" and apply the safe default.
    return null;
  }
}

function emitCodexReviewEventSync(cwd, workflowId, verdict, reason, provider = "codex") {
  const detail = `VERDICT: ${verdict} — workflow=${workflowId} | provider=${provider || "codex"} | ${reason || "no detail"}`;
  const args = [RUNTIME_CLI_PATH, "event", "emit", "codex_stop_review"];
  if (workflowId) {
    // ENFORCE-RCA-16: source key scopes events per-workflow for review
    // observability, statusline, and supervisory consumers — the dispatch
    // engine does not read these events (DEC-PHASE5-STOP-REVIEW-SEPARATION-001).
    args.push("--source", `workflow:${workflowId}`);
  }
  args.push("--detail", detail);
  try {
    execFileSync(
      "python3",
      args,
      { cwd, env: buildPolicyEnv(cwd), timeout: 5000, encoding: "utf8" }
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

  const isSubagentStop = Boolean(input.agent_type);

  if (isSubagentStop) {
    logNote("[review-gate] SubagentStop broad review retired; use role-specific Codex critics.");
    return;
  }

  const jobs = sortJobsNewestFirst(filterJobsForCurrentSession(listJobs(workspaceRoot), input));
  const runningJob = jobs.find((job) => job.status === "queued" || job.status === "running");
  const runningTaskNote = runningJob
    ? `Codex task ${runningJob.id} is still running. Check /codex:status and use /codex:cancel ${runningJob.id} if you want to stop it before ending the session.`
    : null;

  // `config.stopReviewGate` continues to gate only the USER-FACING regular
  // Stop path (the interactive block at turn-end that the user opts into
  // via `codex setup --enable-review-gate`).
  // DEC-CONFIG-AUTHORITY-001: read toggles from policy engine, not flat-file state.
  // readEnforcementConfig returns null on error or missing — fail-CLOSED to "true"
  // (enforce by default) per DEC-REGULAR-STOP-REVIEW-001.
  const regularReviewEnabled  = (readEnforcementConfig(cwd, "review_gate_regular_stop")  || "true") === "true";

  if (!regularReviewEnabled) {
    logNote(runningTaskNote);
    return;
  }

  const workflowId = resolveWorkflowId(cwd, input);
  const review = runStopReview(cwd, input, workflowId);

  // Infrastructure failures that cannot be converted into a reviewer-subagent
  // fallback still allow stop with a warning.
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
    emitCodexReviewEventSync(cwd, workflowId, "BLOCK", review.reason || "review found issues", provider);
    emitDecision({
      decision: "block",
      reason: runningTaskNote
        ? `${runningTaskNote}\n\n[${provider}] ${review.reason}`
        : `[${provider}] ${review.reason}`
    });
    return;
  }

  // PASS — both models agree
  emitCodexReviewEventSync(cwd, workflowId, "ALLOW", review.reason || "work looks good", review.provider || "reviewer");
  if (review.reason) {
    logNote(`Review gate (${review.provider || "reviewer"}) PASS:\n${review.reason}`);
  }
  logNote(runningTaskNote);
}

main();
