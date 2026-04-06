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
const STOP_REVIEW_TASK_MARKER = "Run a stop-gate review of the previous Claude turn.";

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

function readFileHead(filePath, maxLines = 324) {
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

function getRecentGitLog(cwd) {
  try {
    return execFileSync("git", ["log", "--oneline", "-20"], { cwd, encoding: "utf8", timeout: 5000 }).trim();
  } catch {
    return "";
  }
}

function gatherProjectContext(cwd) {
  const sections = [];

  const masterPlan = readFileHead(path.join(cwd, "MASTER_PLAN.md"), 77);
  if (masterPlan) {
    sections.push("## MASTER_PLAN.md — Identity, Architecture, Principles\n" + masterPlan);
  }

  return sections.join("\n\n---\n\n") || "No project context files found.";
}

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

function buildSetupNote(cwd) {
  const authStatus = getCodexLoginStatus(cwd);
  if (authStatus.available && authStatus.loggedIn) {
    return null;
  }

  const detail = authStatus.detail ? ` ${authStatus.detail}.` : "";
  return `Codex is not set up for the review gate.${detail} Run /codex:setup and, if needed, !codex login.`;
}

function parseStopReviewOutput(rawOutput) {
  const text = String(rawOutput ?? "").trim();
  if (!text) {
    return {
      ok: false,
      reason:
        "The stop-time Codex review task returned no final output. Run /codex:review --wait manually or bypass the gate."
    };
  }

  // Support both legacy "ALLOW:/BLOCK:" (first-line) and new "VERDICT: ALLOW/BLOCK" (last-line) formats
  const lines = text.split(/\r?\n/);

  // Scan from the end for the verdict line (new format)
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i].trim();
    if (line.startsWith("VERDICT: ALLOW") || line.startsWith("VERDICT:ALLOW")) {
      const findings = lines.slice(0, i).join("\n").trim();
      return { ok: true, reason: findings || null };
    }
    if (line.startsWith("VERDICT: BLOCK") || line.startsWith("VERDICT:BLOCK")) {
      const findings = lines.slice(0, i).join("\n").trim();
      const verdictReason = line.replace(/^VERDICT:\s*BLOCK[\s—-]*/, "").trim();
      const fullReason = findings
        ? `${findings}\n\n${verdictReason}`
        : verdictReason || text;
      return {
        ok: false,
        reason: `Codex stop-time review found issues:\n\n${fullReason}`
      };
    }
  }

  // Legacy first-line format fallback
  const firstLine = lines[0].trim();
  if (firstLine.startsWith("ALLOW:")) {
    return { ok: true, reason: null };
  }
  if (firstLine.startsWith("BLOCK:")) {
    const reason = firstLine.slice("BLOCK:".length).trim() || text;
    return {
      ok: false,
      reason: `Codex stop-time review found issues that still need fixes before ending the session: ${reason}`
    };
  }

  return {
    ok: false,
    reason:
      "The stop-time Codex review task returned an unexpected answer. Run /codex:review --wait manually or bypass the gate."
  };
}

function runStopReview(cwd, input = {}) {
  const scriptPath = path.join(SCRIPT_DIR, "codex-companion.mjs");
  const prompt = buildStopReviewPrompt(cwd, input);
  const childEnv = {
    ...process.env,
    ...(input.session_id ? { [SESSION_ID_ENV]: input.session_id } : {})
  };
  const result = spawnSync(process.execPath, [scriptPath, "task", "--json", prompt], {
    cwd,
    env: childEnv,
    encoding: "utf8",
    timeout: STOP_REVIEW_TIMEOUT_MS
  });

  if (result.error?.code === "ETIMEDOUT") {
    return {
      ok: false,
      reason:
        "The stop-time Codex review task timed out after 15 minutes. Run /codex:review --wait manually or bypass the gate."
    };
  }

  if (result.status !== 0) {
    const detail = String(result.stderr || result.stdout || "").trim();
    return {
      ok: false,
      reason: detail
        ? `The stop-time Codex review task failed: ${detail}`
        : "The stop-time Codex review task failed. Run /codex:review --wait manually or bypass the gate."
    };
  }

  try {
    const payload = JSON.parse(result.stdout);
    return parseStopReviewOutput(payload?.rawOutput);
  } catch {
    return {
      ok: false,
      reason:
        "The stop-time Codex review task returned invalid JSON. Run /codex:review --wait manually or bypass the gate."
    };
  }
}

function main() {
  const input = readHookInput();
  const cwd = input.cwd || process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const workspaceRoot = resolveWorkspaceRoot(cwd);
  const config = getConfig(workspaceRoot);

  const jobs = sortJobsNewestFirst(filterJobsForCurrentSession(listJobs(workspaceRoot), input));
  const runningJob = jobs.find((job) => job.status === "queued" || job.status === "running");
  const runningTaskNote = runningJob
    ? `Codex task ${runningJob.id} is still running. Check /codex:status and use /codex:cancel ${runningJob.id} if you want to stop it before ending the session.`
    : null;

  if (!config.stopReviewGate) {
    logNote(runningTaskNote);
    return;
  }

  const setupNote = buildSetupNote(cwd);
  if (setupNote) {
    logNote(setupNote);
    logNote(runningTaskNote);
    return;
  }

  const review = runStopReview(cwd, input);
  if (!review.ok) {
    emitDecision({
      decision: "block",
      reason: runningTaskNote ? `${runningTaskNote} ${review.reason}` : review.reason
    });
    return;
  }

  if (review.reason) {
    logNote(`Codex review (ALLOW):\n${review.reason}`);
  }
  logNote(runningTaskNote);
}

main();
