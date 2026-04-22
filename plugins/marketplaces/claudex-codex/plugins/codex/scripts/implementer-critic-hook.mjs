#!/usr/bin/env node

// @decision DEC-IMPLEMENTER-CRITIC-HOOK-001 — dedicated Codex critic hook persists implementer routing verdicts
// Why: The implementer critic is workflow authority, not a generic advisory stop gate, so it needs its own prompt, schema, persistence path, and retry/convergence context.
// Alternatives considered: Extending stop-review-gate-hook.mjs in place was rejected because PASS/CONTINUE semantics blur ordinary Stop audit with implementer workflow routing; relying on generic events alone was rejected because retry limits and no-convergence state need runtime-owned records.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

import {
  getCodexLoginStatus,
  parseStructuredOutput,
  readOutputSchema,
  runAppServerTurn
} from "./lib/codex.mjs";
import { loadPromptTemplate, interpolateTemplate } from "./lib/prompts.mjs";
import { resolveWorkspaceRoot } from "./lib/workspace.mjs";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = path.resolve(SCRIPT_DIR, "..");
const CRITIC_SCHEMA = path.join(ROOT_DIR, "schemas", "critic-output.schema.json");
const SOURCE_EXTENSIONS = /\.(ts|tsx|js|jsx|mjs|cjs|mts|cts|py|rs|go|java|kt|swift|c|cpp|h|hpp|cs|rb|php|sh|bash|zsh)$/;
const SKIPPABLE_PATH = /(\.config\.|\.test\.|\.spec\.|__tests__|\.generated\.|\.min\.|node_modules|vendor|dist|build|\.next|__pycache__|\.git)/;

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

function sanitizeToken(raw) {
  return String(raw ?? "")
    .replace(/[/: ]/g, "-")
    .replace(/[^A-Za-z0-9._-]/g, "")
    || "default";
}

function runCommand(cwd, command, args) {
  try {
    return execFileSync(command, args, {
      cwd,
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"]
    }).trim();
  } catch {
    return "";
  }
}

function currentWorkflowId(cwd) {
  const branch = runCommand(cwd, "git", ["rev-parse", "--abbrev-ref", "HEAD"]);
  if (branch && branch !== "HEAD") {
    return sanitizeToken(branch);
  }
  return sanitizeToken(path.basename(cwd));
}

function localCliPath() {
  return path.resolve(SCRIPT_DIR, "..", "..", "..", "..", "..", "..", "runtime", "cli.py");
}

function readPolicyJson(cwd, args) {
  const env = { ...process.env };
  const workspaceRoot = resolveWorkspaceRoot(cwd);
  if (!env.CLAUDE_PROJECT_DIR) {
    env.CLAUDE_PROJECT_DIR = workspaceRoot;
  }
  if (!env.CLAUDE_POLICY_DB) {
    env.CLAUDE_POLICY_DB = path.join(env.CLAUDE_PROJECT_DIR, ".claude", "state.db");
  }
  const raw = execFileSync(
    "python3",
    [localCliPath(), ...args],
    {
      cwd: workspaceRoot,
      env,
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"]
    }
  );
  return JSON.parse(raw);
}

function resolveCriticContext(cwd) {
  try {
    const lease = readPolicyJson(cwd, ["lease", "current", "--worktree-path", cwd]);
    if (lease?.found) {
      return {
        workflowId: String(lease.workflow_id || currentWorkflowId(cwd)),
        leaseId: String(lease.lease_id || "")
      };
    }
  } catch {
    // Fall through to branch-derived workflow identity.
  }
  return {
    workflowId: currentWorkflowId(cwd),
    leaseId: ""
  };
}

function submitCriticReview(cwd, payload) {
  const args = [
    "critic-review", "submit",
    "--workflow-id", payload.workflowId,
    "--role", "implementer",
    "--provider", payload.provider || "codex",
    "--verdict", payload.verdict,
    "--summary", payload.summary || "",
    "--detail", payload.detail || "",
    "--fingerprint", payload.fingerprint || "",
    "--project-root", cwd,
    "--metadata", JSON.stringify(payload.metadata || {})
  ];
  if (payload.leaseId) {
    args.push("--lease-id", payload.leaseId);
  }
  return readPolicyJson(cwd, args);
}

function readFileHead(filePath, maxLines) {
  try {
    const content = fs.readFileSync(filePath, "utf8");
    const lines = content.split("\n");
    if (lines.length <= maxLines) {
      return content;
    }
    return `${lines.slice(0, maxLines).join("\n")}\n... (truncated)`;
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
      if (!/^### INIT-/.test(line) || /\(completed\b/.test(line)) {
        i += 1;
        continue;
      }
      const block = [line];
      i += 1;
      while (i < lines.length && !lines[i].startsWith("### ")) {
        const trimmed = lines[i].trimStart();
        if (trimmed.startsWith("- **Status:**") || trimmed.startsWith("- **Goal:**")) {
          block.push(lines[i]);
        }
        i += 1;
      }
      if (block.length > 1) {
        summaries.push(block.join("\n"));
      }
    }
    return summaries.join("\n\n");
  } catch {
    return "";
  }
}

function gatherProjectContext(cwd) {
  const sections = [];
  const planPath = path.join(cwd, "MASTER_PLAN.md");
  const masterPlan = readFileHead(planPath, 77);
  if (masterPlan) {
    sections.push(`## MASTER_PLAN.md\n${masterPlan}`);
  }
  const initiatives = extractInitiativeSummary(planPath);
  if (initiatives) {
    sections.push(`## Active Initiatives\n${initiatives}`);
  }
  return sections.join("\n\n---\n\n") || "No project context files found.";
}

function getRecentGitLog(cwd) {
  return runCommand(cwd, "git", ["log", "--oneline", "-20"]);
}

function getDiffStat(cwd) {
  const tracked = runCommand(cwd, "git", ["diff", "--stat", "HEAD"]);
  const untracked = runCommand(cwd, "git", ["ls-files", "--others", "--exclude-standard"]);
  const parts = [];
  if (tracked) {
    parts.push(tracked);
  }
  if (untracked) {
    parts.push(`Untracked files:\n${untracked}`);
  }
  return parts.join("\n\n");
}

function getChangedFileCount(cwd) {
  const output = runCommand(cwd, "git", ["status", "--porcelain"]);
  return output ? output.split("\n").filter(Boolean).length : 0;
}

function buildScopeHint(changedFiles) {
  if (changedFiles === 0) {
    return "No uncommitted changes detected. Verify whether the implementer actually changed code before choosing READY_FOR_REVIEWER.";
  }
  if (changedFiles <= 5) {
    return `Worktree has ${changedFiles} dirty files. Full tactical review is expected.`;
  }
  if (changedFiles < 15) {
    return `Worktree has ${changedFiles} dirty files. Focus on files likely touched by the implementer and the immediate integration surfaces.`;
  }
  return `Worktree has ${changedFiles} dirty files. Prioritize the implementer's claimed files, runtime/hook wiring, and tests before emitting TRY_AGAIN or BLOCKED_BY_PLAN.`;
}

function buildCriticPrompt(cwd, input = {}) {
  const template = loadPromptTemplate(ROOT_DIR, "implementer-critic");
  const responseText = String(
    input.last_assistant_message
      ?? input.assistant_response
      ?? input.response
      ?? input.result
      ?? input.output
      ?? ""
  ).trim();
  const responseBlock = responseText
    ? ["Implementer response:", responseText].join("\n")
    : "Implementer response unavailable.";
  return interpolateTemplate(template, {
    IMPLEMENTER_RESPONSE_BLOCK: responseBlock,
    PROJECT_CONTEXT_BLOCK: gatherProjectContext(cwd),
    GIT_LOG_BLOCK: getRecentGitLog(cwd) || "No recent git activity.",
    DIFF_STAT_BLOCK: getDiffStat(cwd) || "No diff available.",
    SCOPE_HINT: buildScopeHint(getChangedFileCount(cwd))
  });
}

function isSourceFile(file) {
  return SOURCE_EXTENSIONS.test(file);
}

function isSkippablePath(file) {
  return SKIPPABLE_PATH.test(file);
}

function computeSourceFingerprint(cwd) {
  const tracked = runCommand(cwd, "git", ["diff", "--name-only", "HEAD"]);
  const untracked = runCommand(cwd, "git", ["ls-files", "--others", "--exclude-standard"]);
  const files = [...new Set(
    `${tracked}\n${untracked}`
      .split(/\r?\n/)
      .map((value) => value.trim())
      .filter(Boolean)
  )].sort();

  let body = "";
  for (const rel of files) {
    if (!isSourceFile(rel) || isSkippablePath(rel)) {
      continue;
    }
    const abs = path.join(cwd, rel);
    let fileHash = "DELETED";
    try {
      if (fs.existsSync(abs) && fs.statSync(abs).isFile()) {
        fileHash = crypto.createHash("sha256").update(fs.readFileSync(abs)).digest("hex");
      }
    } catch {
      fileHash = "NOHASH";
    }
    body += `${rel}:${fileHash}\n`;
  }
  if (!body) {
    return "EMPTY";
  }
  return crypto.createHash("sha256").update(body).digest("hex");
}

function resolveTestReview() {
  const raw = process.env.CLAUDEX_IMPLEMENTER_CRITIC_TEST_RESPONSE;
  if (!raw) {
    return null;
  }
  try {
    const parsed = JSON.parse(raw);
    return {
      verdict: String(parsed.verdict || ""),
      summary: String(parsed.summary || "Implementer critic test override."),
      detail: String(parsed.detail || parsed.summary || "Implementer critic test override."),
      nextSteps: Array.isArray(parsed.next_steps) ? parsed.next_steps.map(String) : [],
      rawOutput: raw,
      progressLines: Array.isArray(parsed.progress)
        ? parsed.progress.map((item) => String(item))
        : ["Using implementer critic test override."],
      provider: "codex"
    };
  } catch {
    return null;
  }
}

async function runCritic(cwd, input = {}) {
  const testReview = resolveTestReview();
  if (testReview) {
    for (const line of testReview.progressLines) {
      logNote(`[implementer-critic] ${line}`);
    }
    return testReview;
  }

  const status = getCodexLoginStatus(cwd);
  if (!status.available || !status.loggedIn) {
    return {
      verdict: "CRITIC_UNAVAILABLE",
      summary: "Codex critic unavailable.",
      detail: status.detail || "Codex is unavailable or not authenticated.",
      nextSteps: ["Route to reviewer adjudication."],
      rawOutput: "",
      progressLines: [
        "Starting Codex tactical critic (read-only).",
        `Provider status: codex unavailable (${status.detail || "unknown"}).`
      ],
      provider: "codex"
    };
  }

  const prompt = buildCriticPrompt(cwd, input);
  const progressLines = [
    "Starting Codex tactical critic (read-only).",
    "Provider status: codex ready."
  ];
  const onProgress = (update) => {
    const message = typeof update === "string" ? update : update?.message;
    if (!message) {
      return;
    }
    logNote(`[implementer-critic] ${message}`);
    if (progressLines.length < 6) {
      progressLines.push(message);
    }
  };

  try {
    const result = await runAppServerTurn(cwd, {
      prompt,
      sandbox: "read-only",
      outputSchema: readOutputSchema(CRITIC_SCHEMA),
      onProgress
    });
    const parsed = parseStructuredOutput(result.finalMessage, {
      status: result.status,
      failureMessage: result.error?.message ?? result.stderr
    });
    if (parsed.parseError || !parsed.parsed) {
      return {
        verdict: "CRITIC_UNAVAILABLE",
        summary: "Codex critic returned invalid structured output.",
        detail: parsed.parseError || "Codex did not return a structured verdict.",
        nextSteps: ["Route to reviewer adjudication."],
        rawOutput: parsed.rawOutput || result.finalMessage || "",
        progressLines,
        provider: "codex"
      };
    }

    return {
      verdict: String(parsed.parsed.verdict || ""),
      summary: String(parsed.parsed.summary || ""),
      detail: String(parsed.parsed.detail || ""),
      nextSteps: Array.isArray(parsed.parsed.next_steps)
        ? parsed.parsed.next_steps.map((item) => String(item))
        : [],
      rawOutput: parsed.rawOutput || result.finalMessage || "",
      progressLines,
      provider: "codex"
    };
  } catch (error) {
    return {
      verdict: "CRITIC_UNAVAILABLE",
      summary: "Codex critic failed before producing a verdict.",
      detail: error instanceof Error ? error.message : String(error),
      nextSteps: ["Route to reviewer adjudication."],
      rawOutput: "",
      progressLines,
      provider: "codex"
    };
  }
}

function buildHookOutput(review, submitResult, workflowId) {
  const resolution = submitResult?.resolution || {};
  const lines = ["Implementer critic progress: Starting Codex tactical critic (read-only)."];
  for (const line of review.progressLines || []) {
    lines.push(`Implementer critic progress: ${line}`);
  }
  lines.push(
    `Implementer critic: provider=${review.provider || "codex"}, workflow=${workflowId || "unknown"}.`
  );
  lines.push(
    `Implementer critic: verdict=${resolution.verdict || review.verdict}, next_role=${resolution.next_role || "reviewer"}.`
  );

  if ((resolution.verdict || review.verdict) === "TRY_AGAIN") {
    if (resolution.escalated) {
      lines.push(
        `Implementer critic: reviewer adjudication after ${resolution.escalation_reason || "retry escalation"}.`
      );
    } else {
      lines.push(
        `Implementer critic: retry ${resolution.try_again_streak || 0} of ${resolution.retry_limit ?? 0} before reviewer escalation.`
      );
    }
    if ((resolution.repeated_fingerprint_streak || 0) >= 2) {
      lines.push(
        `Implementer critic: repeated fingerprint streak ${resolution.repeated_fingerprint_streak}.`
      );
    }
  }

  if (review.summary) {
    lines.push(`Implementer critic summary: ${review.summary}`);
  }
  if (review.detail) {
    lines.push(`Implementer critic detail: ${review.detail}`);
  }
  return { additionalContext: lines.join("\n") };
}

async function main() {
  const input = readHookInput();
  const agentType = String(input.agent_type ?? input.agentType ?? "").toLowerCase();
  if (agentType && agentType !== "implementer") {
    return;
  }

  const cwd = resolveWorkspaceRoot(
    input.cwd || process.env.CLAUDE_PROJECT_DIR || process.cwd()
  );
  const criticContext = resolveCriticContext(cwd);
  const review = await runCritic(cwd, input);
  const fingerprint = computeSourceFingerprint(cwd);
  const metadata = {
    hook: "implementer-critic-hook.mjs",
    raw_output: review.rawOutput || "",
    next_steps: review.nextSteps || [],
    progress_lines: review.progressLines || []
  };
  const submitResult = submitCriticReview(cwd, {
    workflowId: criticContext.workflowId,
    leaseId: criticContext.leaseId,
    provider: review.provider || "codex",
    verdict: review.verdict,
    summary: review.summary,
    detail: review.detail,
    fingerprint,
    metadata
  });

  emitDecision(buildHookOutput(review, submitResult, criticContext.workflowId));
}

main().catch((error) => {
  logNote(
    `[implementer-critic] ${
      error instanceof Error ? (error.stack || error.message) : String(error)
    }`
  );
  process.exit(1);
});
