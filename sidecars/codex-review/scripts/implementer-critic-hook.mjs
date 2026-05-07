#!/usr/bin/env node

// @decision DEC-IMPLEMENTER-CRITIC-HOOK-001 — dedicated Codex critic hook persists implementer routing verdicts
// Why: The implementer critic is workflow authority, not a generic advisory stop gate, so it needs its own prompt, schema, persistence path, and retry/convergence context.
// Alternatives considered: Extending stop-review-gate-hook.mjs in place was rejected because PASS/CONTINUE semantics blur ordinary Stop audit with implementer workflow routing; relying on generic events alone was rejected because retry limits and no-convergence state need runtime-owned records.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { execFileSync, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

import {
  getCodexLoginStatus,
  parseStructuredOutput,
  readOutputSchema,
  runAppServerTurn
} from "./lib/codex.mjs";
import { binaryAvailable } from "./lib/process.mjs";
import { loadPromptTemplate, interpolateTemplate } from "./lib/prompts.mjs";
import { resolveWorkspaceRoot } from "./lib/workspace.mjs";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = path.resolve(SCRIPT_DIR, "..");
const REPO_ROOT = path.resolve(ROOT_DIR, "../..");
const RUNTIME_CLI_PATH =
  process.env.CLAUDE_RUNTIME_CLI || path.resolve(REPO_ROOT, "runtime/cli.py");
const CRITIC_SCHEMA = path.join(ROOT_DIR, "schemas", "critic-output.schema.json");
const POLICY_DIR = path.resolve(ROOT_DIR, "policies");
const REVIEW_PROVIDER_KEY = "review_gate_provider";
const SOURCE_EXTENSIONS = /\.(ts|tsx|js|jsx|mjs|cjs|mts|cts|astro|vue|svelte|css|scss|sass|less|html|htm|py|rs|go|java|kt|swift|c|cpp|h|hpp|cs|rb|php|sh|bash|zsh)$/;
const SKIPPABLE_PATH = /(\.generated\.|\.min\.|(^|\/)(node_modules|vendor|dist|build|\.next|__pycache__|\.git)(\/|$))/;
const VALID_REVIEW_PROVIDERS = new Set(["auto", "codex", "gemini", "reviewer-subagent"]);

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
  return RUNTIME_CLI_PATH;
}

function execPolicyJson(cwd, args, env) {
  const raw = execFileSync(
    "python3",
    [localCliPath(), ...args],
    {
      cwd,
      env,
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"]
    }
  );
  return JSON.parse(raw);
}

const POLICY_DB_OVERRIDE_CACHE = new Map();

function homePolicyDb() {
  if (!process.env.HOME) {
    return "";
  }
  return path.join(process.env.HOME, ".claude", "state.db");
}

function resolvePolicyDbOverride(cwd, workspaceRoot) {
  if (process.env.CLAUDE_POLICY_DB) {
    return process.env.CLAUDE_POLICY_DB;
  }
  const cacheKey = `${workspaceRoot}\0${cwd}`;
  if (POLICY_DB_OVERRIDE_CACHE.has(cacheKey)) {
    return POLICY_DB_OVERRIDE_CACHE.get(cacheKey);
  }

  const baseEnv = { ...process.env, CLAUDE_PROJECT_DIR: workspaceRoot };
  delete baseEnv.CLAUDE_POLICY_DB;
  try {
    const lease = execPolicyJson(
      workspaceRoot,
      ["lease", "current", "--worktree-path", cwd],
      baseEnv
    );
    if (lease?.found) {
      POLICY_DB_OVERRIDE_CACHE.set(cacheKey, "");
      return "";
    }
  } catch {
    // Probe only; the real command below will surface actionable failures.
  }

  const homeDb = homePolicyDb();
  if (homeDb && fs.existsSync(homeDb)) {
    try {
      const lease = execPolicyJson(
        workspaceRoot,
        ["lease", "current", "--worktree-path", cwd],
        { ...baseEnv, CLAUDE_POLICY_DB: homeDb }
      );
      if (lease?.found) {
        POLICY_DB_OVERRIDE_CACHE.set(cacheKey, homeDb);
        return homeDb;
      }
    } catch {
      // Keep the default resolver path when the control-plane DB is unreadable.
    }
  }

  POLICY_DB_OVERRIDE_CACHE.set(cacheKey, "");
  return "";
}

function readPolicyJson(cwd, args) {
  const env = { ...process.env };
  const workspaceRoot = resolveWorkspaceRoot(cwd);
  env.CLAUDE_PROJECT_DIR = workspaceRoot;
  if (!env.CLAUDE_POLICY_DB) {
    const override = resolvePolicyDbOverride(cwd, workspaceRoot);
    if (override) {
      env.CLAUDE_POLICY_DB = override;
    }
  }
  return execPolicyJson(workspaceRoot, args, env);
}

function normalizeReviewProvider(value) {
  const normalized = String(value || "").trim().toLowerCase();
  if (!normalized) {
    return "codex";
  }
  const dashed = normalized.replace(/_/g, "-");
  if (dashed === "reviewer" || dashed === "reviewer-subagent-fallback") {
    return "reviewer-subagent";
  }
  return VALID_REVIEW_PROVIDERS.has(dashed) ? dashed : "codex";
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

function telemetryProvider(provider) {
  const order = providerOrder(provider);
  return order[0] || "external-critic";
}

function readConfiguredReviewProvider(cwd, workflowId = "") {
  const envOverride =
    process.env.CLAUDEX_IMPLEMENTER_CRITIC_PROVIDER ||
    process.env.CLAUDEX_REVIEW_PROVIDER ||
    "";
  if (envOverride) {
    return normalizeReviewProvider(envOverride);
  }
  try {
    const args = [
      "config", "get", REVIEW_PROVIDER_KEY,
      "--project-root", cwd
    ];
    if (workflowId) {
      args.push("--workflow-id", workflowId);
    }
    const config = readPolicyJson(cwd, args);
    return normalizeReviewProvider(config?.value || "codex");
  } catch {
    return "codex";
  }
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

function startCriticRun(cwd, payload) {
  const args = [
    "critic-run", "start",
    "--workflow-id", payload.workflowId,
    "--role", "implementer",
    "--provider", payload.provider || "codex"
  ];
  if (payload.leaseId) {
    args.push("--lease-id", payload.leaseId);
  }
  return readPolicyJson(cwd, args);
}

function recordCriticProgress(cwd, runId, message, options = {}) {
  if (!runId || !message) {
    return null;
  }
  try {
    const args = [
      "critic-run", "progress",
      "--run-id", runId,
      "--message", String(message),
    ];
    if (options.phase) {
      args.push("--phase", String(options.phase));
    }
    if (options.status) {
      args.push("--status", String(options.status));
    }
    return readPolicyJson(cwd, args);
  } catch (error) {
    logNote(`[implementer-critic] Failed to record progress: ${error instanceof Error ? error.message : String(error)}`);
    return null;
  }
}

function completeCriticRun(cwd, runId, payload) {
  if (!runId) {
    return null;
  }
  try {
    const args = [
      "critic-run", "complete",
      "--run-id", runId,
      "--provider", payload.provider || "codex",
      "--verdict", payload.verdict,
      "--summary", payload.summary || "",
      "--detail", payload.detail || "",
      "--artifact-path", payload.artifactPath || "",
      "--fingerprint", payload.fingerprint || "",
      "--metrics", JSON.stringify(payload.metrics || {})
    ];
    if (payload.reviewId != null) {
      args.push("--review-id", String(payload.reviewId));
    }
    if (payload.fallback) {
      args.push("--fallback", payload.fallback);
    }
    if (payload.error) {
      args.push("--error", payload.error);
    }
    return readPolicyJson(cwd, args);
  } catch (error) {
    logNote(`[implementer-critic] Failed to complete critic run: ${error instanceof Error ? error.message : String(error)}`);
    return null;
  }
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
      findings: normalizeFindings(parsed.findings),
      nextSteps: Array.isArray(parsed.next_steps) ? parsed.next_steps.map(String) : [],
      rawOutput: raw,
      executionProof: {
        provider: "test",
        test_override: true,
        parsed_structured_output_present: true
      },
      progressLines: Array.isArray(parsed.progress)
        ? parsed.progress.map((item) => String(item))
        : ["Using implementer critic test override."],
      providerStatuses: [],
      configuredProvider: "test",
      provider: "codex"
    };
  } catch {
    return null;
  }
}

function normalizeFindings(value) {
  if (!Array.isArray(value)) {
    return [];
  }
  return value
    .map((item) => String(item || "").trim())
    .filter(Boolean);
}

function getGeminiLoginStatus(cwd) {
  const versionStatus = binaryAvailable("gemini", ["--version"], { cwd });
  if (!versionStatus.available) {
    return {
      available: false,
      loggedIn: false,
      detail: versionStatus.detail
    };
  }

  if (process.env.GEMINI_API_KEY || process.env.GOOGLE_API_KEY) {
    return {
      available: true,
      loggedIn: true,
      detail: `${versionStatus.detail}; API key present`
    };
  }

  const home = process.env.HOME || process.env.USERPROFILE || "";
  const credsPath = home ? path.join(home, ".gemini", "oauth_creds.json") : "";
  if (credsPath && fs.existsSync(credsPath)) {
    return {
      available: true,
      loggedIn: true,
      detail: `${versionStatus.detail}; oauth credentials present`
    };
  }

  return {
    available: true,
    loggedIn: false,
    detail: `${versionStatus.detail}; not authenticated`
  };
}

function extractGeminiResponse(stdout) {
  const text = String(stdout || "").trim();
  if (!text) {
    return "";
  }
  try {
    const payload = JSON.parse(text);
    if (payload && typeof payload === "object") {
      if (typeof payload.response === "string") {
        return payload.response;
      }
      if (typeof payload.text === "string") {
        return payload.text;
      }
      if (typeof payload.output === "string") {
        return payload.output;
      }
      if (typeof payload.message === "string") {
        return payload.message;
      }
      if (typeof payload.verdict === "string") {
        return JSON.stringify(payload);
      }
    }
  } catch {
    return text;
  }
  return text;
}

function runGeminiCritic(cwd, prompt) {
  const policyPath = path.join(POLICY_DIR, "stop-gate-readonly.toml");
  const args = [
    "-p", prompt,
    "--approval-mode", "plan",
    "--output-format", "json"
  ];
  if (fs.existsSync(policyPath)) {
    args.push("--policy", policyPath);
  }

  const result = spawnSync("gemini", args, {
    cwd,
    encoding: "utf8",
    timeout: 15 * 60 * 1000,
    stdio: ["pipe", "pipe", "pipe"]
  });

  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    const detail = String(result.stderr || result.stdout || `exit ${result.status}`).trim();
    throw new Error(detail || "Gemini critic process failed.");
  }

  const rawOutput = extractGeminiResponse(result.stdout);
  const parsed = parseStructuredOutput(rawOutput, {
    status: result.status,
    failureMessage: result.stderr
  });
  if (parsed.parseError || !parsed.parsed) {
    return {
      verdict: "CRITIC_UNAVAILABLE",
      summary: "Gemini critic returned invalid structured output.",
      detail: parsed.parseError || "Gemini did not return a structured verdict.",
      findings: ["Gemini returned invalid structured output."],
      nextSteps: ["Fix Gemini critic output so it returns the required structured verdict."],
      rawOutput: parsed.rawOutput || rawOutput || "",
      progressLines: [],
      provider: "gemini"
    };
  }

  return {
    verdict: String(parsed.parsed.verdict || ""),
    summary: String(parsed.parsed.summary || ""),
    detail: String(parsed.parsed.detail || ""),
    findings: normalizeFindings(parsed.parsed.findings),
    nextSteps: Array.isArray(parsed.parsed.next_steps)
      ? parsed.parsed.next_steps.map((item) => String(item))
      : [],
    rawOutput: parsed.rawOutput || rawOutput || "",
    executionProof: {
      provider: "gemini",
      exit_code: result.status,
      parsed_structured_output_present: true,
      raw_response_non_empty: Boolean(String(rawOutput || "").trim())
    },
    progressLines: [],
    provider: "gemini"
  };
}

function unavailableExternalCritic(providerStatuses, configuredProvider) {
  const statusDetail = providerStatuses
    .map((item) => `${item.provider}: ${item.ready ? "ready" : "unavailable"} (${item.detail || "no detail"})`)
    .join("; ");
  return {
    verdict: "CRITIC_UNAVAILABLE",
    summary: "External implementer critic did not run.",
    detail: statusDetail || "No external critic provider returned valid structured output.",
    nextSteps: [
      "Fix the configured critic provider or disable critic_enabled_implementer_stop explicitly for this workflow/project.",
      "Re-run the implementer stop after a real Codex or Gemini critic can produce structured output."
    ],
    findings: ["No external critic provider completed a structured review."],
    rawOutput: "",
    executionProof: {
      provider: "external-critic",
      parsed_structured_output_present: false,
      provider_failures: providerStatuses
    },
    progressLines: [
      `Review provider preference: ${configuredProvider}.`,
      ...providerStatuses.map((item) => (
        `Provider status: ${item.provider} ${item.ready ? "ready" : "unavailable"} (${item.detail || "no detail"}).`
      )),
      "Critic failed closed: no external provider produced a structured review."
    ],
    providerStatuses,
    configuredProvider,
    fallback: "",
    provider: "external-critic"
  };
}

async function runCritic(cwd, input = {}, options = {}) {
  const testReview = resolveTestReview();
  if (testReview) {
    for (const line of testReview.progressLines) {
      logNote(`[implementer-critic] ${line}`);
      recordCriticProgress(cwd, options.runId || "", line, {
        phase: "test",
        status: "reviewing"
      });
    }
    return testReview;
  }

  const configuredProvider = readConfiguredReviewProvider(cwd, options.workflowId || "");
  const providerStatuses = [];
  const prompt = buildCriticPrompt(cwd, input);
  const progressLines = [
    "Starting tactical review critic (read-only).",
    `Review provider preference: ${configuredProvider}.`
  ];
  const onProgress = (update) => {
    const message = typeof update === "string" ? update : update?.message;
    if (!message) {
      return;
    }
    logNote(`[implementer-critic] ${message}`);
    recordCriticProgress(cwd, options.runId || "", message, {
      phase: typeof update === "object" && update?.phase ? update.phase : "reviewing",
      status: "reviewing"
    });
    if (progressLines.length < 6) {
      progressLines.push(message);
    }
  };

  if (normalizeReviewProvider(configuredProvider) === "reviewer-subagent") {
    providerStatuses.push({
      provider: "configuration",
      ready: false,
      detail: "reviewer-subagent is not an external implementer critic provider"
    });
  }

  for (const provider of providerOrder(configuredProvider)) {
    if (provider === "codex") {
      const status = getCodexLoginStatus(cwd);
      providerStatuses.push({
        provider: "codex",
        ready: Boolean(status.available && status.loggedIn),
        detail: status.detail || "unknown"
      });
      if (!status.available || !status.loggedIn) {
        const line = `Provider status: codex unavailable (${status.detail || "unknown"}).`;
        progressLines.push(line);
        logNote(`[implementer-critic] ${line}`);
        recordCriticProgress(cwd, options.runId || "", line, {
          phase: "provider",
          status: "provider_ready"
        });
        continue;
      }
      progressLines.push("Provider status: codex ready.");
      recordCriticProgress(cwd, options.runId || "", "Provider status: codex ready.", {
        phase: "provider",
        status: "provider_ready"
      });
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
          const detail = parsed.parseError || "Codex did not return a structured verdict.";
          providerStatuses.push({ provider: "codex", ready: true, failed: true, detail });
          progressLines.push(`Provider failure: codex invalid output (${detail}).`);
          recordCriticProgress(cwd, options.runId || "", `Provider failure: codex invalid output (${detail}).`, {
            phase: "provider",
            status: "reviewing"
          });
          continue;
        }

        const proof = {
          provider: "codex",
          app_server_thread_id: result.threadId || "",
          thread_id: result.threadId || "",
          turn_id: result.turnId || "",
          turn_status: result.turn?.status || "",
          parsed_structured_output_present: true,
          final_message_non_empty: Boolean(String(result.finalMessage || "").trim())
        };
        if (!proof.thread_id || !proof.turn_id || proof.turn_status !== "completed" || !proof.final_message_non_empty) {
          const detail = "Codex critic completed without required execution proof fields.";
          providerStatuses.push({ provider: "codex", ready: true, failed: true, detail });
          progressLines.push(`Provider failure: codex proof invalid (${detail}).`);
          recordCriticProgress(cwd, options.runId || "", `Provider failure: codex proof invalid (${detail}).`, {
            phase: "provider",
            status: "reviewing"
          });
          continue;
        }

        return {
          verdict: String(parsed.parsed.verdict || ""),
          summary: String(parsed.parsed.summary || ""),
          detail: String(parsed.parsed.detail || ""),
          findings: normalizeFindings(parsed.parsed.findings),
          nextSteps: Array.isArray(parsed.parsed.next_steps)
            ? parsed.parsed.next_steps.map((item) => String(item))
            : [],
          rawOutput: parsed.rawOutput || result.finalMessage || "",
          executionProof: proof,
          progressLines,
          providerStatuses,
          configuredProvider,
          provider: "codex"
        };
      } catch (error) {
        const detail = error instanceof Error ? error.message : String(error);
        providerStatuses.push({ provider: "codex", ready: true, failed: true, detail });
        progressLines.push(`Provider failure: codex failed (${detail}).`);
        recordCriticProgress(cwd, options.runId || "", `Provider failure: codex failed (${detail}).`, {
          phase: "provider",
          status: "reviewing"
        });
        continue;
      }
    }

    if (provider === "gemini") {
      const status = getGeminiLoginStatus(cwd);
      providerStatuses.push({
        provider: "gemini",
        ready: Boolean(status.available && status.loggedIn),
        detail: status.detail || "unknown"
      });
      if (!status.available || !status.loggedIn) {
        const line = `Provider status: gemini unavailable (${status.detail || "unknown"}).`;
        progressLines.push(line);
        logNote(`[implementer-critic] ${line}`);
        recordCriticProgress(cwd, options.runId || "", line, {
          phase: "provider",
          status: "provider_ready"
        });
        continue;
      }
      progressLines.push("Provider status: gemini ready.");
      recordCriticProgress(cwd, options.runId || "", "Provider status: gemini ready.", {
        phase: "provider",
        status: "provider_ready"
      });
      try {
        const review = runGeminiCritic(cwd, prompt);
        if (review.verdict === "CRITIC_UNAVAILABLE") {
          providerStatuses.push({
            provider: "gemini",
            ready: true,
            failed: true,
            detail: review.detail || "invalid output"
          });
          progressLines.push(`Provider failure: gemini invalid output (${review.detail || "unknown"}).`);
          recordCriticProgress(cwd, options.runId || "", `Provider failure: gemini invalid output (${review.detail || "unknown"}).`, {
            phase: "provider",
            status: "reviewing"
          });
          continue;
        }
        return {
          ...review,
          progressLines: [...progressLines, ...(review.progressLines || [])],
          providerStatuses,
          configuredProvider,
          provider: "gemini"
        };
      } catch (error) {
        const detail = error instanceof Error ? error.message : String(error);
        providerStatuses.push({ provider: "gemini", ready: true, failed: true, detail });
        progressLines.push(`Provider failure: gemini failed (${detail}).`);
        recordCriticProgress(cwd, options.runId || "", `Provider failure: gemini failed (${detail}).`, {
          phase: "provider",
          status: "reviewing"
        });
        continue;
      }
    }
  }

  return unavailableExternalCritic(providerStatuses, configuredProvider);
}

function buildHookOutput(review, submitResult, workflowId) {
  const resolution = submitResult?.resolution || {};
  const lines = ["Implementer critic progress: Starting tactical review critic (read-only)."];
  for (const line of review.progressLines || []) {
    lines.push(`Implementer critic progress: ${line}`);
  }
  lines.push(
    `Implementer critic: provider=${review.provider || "codex"}, workflow=${workflowId || "unknown"}.`
  );
  lines.push(
    `Implementer critic: verdict=${resolution.verdict || review.verdict}, next_role=${resolution.next_role || "none"}.`
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
  if (Array.isArray(review.findings) && review.findings.length > 0) {
    lines.push("Implementer critic findings:");
    for (const finding of review.findings) {
      lines.push(`- ${finding}`);
    }
  }
  if (Array.isArray(review.nextSteps) && review.nextSteps.length > 0) {
    lines.push("Implementer critic next steps:");
    for (const step of review.nextSteps) {
      lines.push(`- ${step}`);
    }
  }
  const verdict = resolution.verdict || review.verdict;
  if (verdict === "TRY_AGAIN") {
    lines.push("Implementer critic action: re-dispatch implementer with the critic detail and next steps verbatim.");
  } else if (verdict === "BLOCKED_BY_PLAN") {
    lines.push("Implementer critic action: re-dispatch planner with the critic detail and next steps verbatim.");
  } else if (verdict === "CRITIC_UNAVAILABLE") {
    lines.push("Implementer critic action: fail closed; no automatic reviewer fallback is allowed.");
  }
  lines.push("USER_VISIBLE_CRITIC_DIGEST:");
  lines.push(`Implementer critic: ${verdict || review.verdict || "unknown"} -> ${resolution.next_role || "none"}`);
  if (review.summary) {
    lines.push(`Summary: ${review.summary}`);
  }
  if (Array.isArray(review.findings) && review.findings.length > 0) {
    lines.push("Highlights:");
    for (const finding of review.findings.slice(0, 4)) {
      lines.push(`- ${finding}`);
    }
  }
  if (Array.isArray(review.nextSteps) && review.nextSteps.length > 0) {
    lines.push("Next:");
    for (const step of review.nextSteps.slice(0, 4)) {
      lines.push(`- ${step}`);
    }
  }
  const additionalContext = lines.join("\n");
  return {
    additionalContext,
    hookSpecificOutput: {
      hookEventName: "SubagentStop",
      additionalContext
    }
  };
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
  const configuredProvider = readConfiguredReviewProvider(cwd, criticContext.workflowId);
  let criticRun = null;
  try {
    criticRun = startCriticRun(cwd, {
      workflowId: criticContext.workflowId,
      leaseId: criticContext.leaseId,
      provider: telemetryProvider(configuredProvider)
    });
  } catch (error) {
    logNote(`[implementer-critic] Failed to start critic telemetry: ${error instanceof Error ? error.message : String(error)}`);
  }
  const runId = criticRun?.run_id || "";
  recordCriticProgress(cwd, runId, `Review provider preference: ${configuredProvider}.`, {
    phase: "provider",
    status: "started"
  });
  const review = await runCritic(cwd, input, {
    workflowId: criticContext.workflowId,
    runId
  });
  const fingerprint = computeSourceFingerprint(cwd);
  const artifactRef = runId ? `state.db:critic-run:${runId}` : "state.db:critic-review";
  const metadata = {
    hook: "implementer-critic-hook.mjs",
    artifact_ref: artifactRef,
    configured_provider: review.configuredProvider || "",
    provider_statuses: review.providerStatuses || [],
    fallback: review.fallback || "",
    raw_output: review.rawOutput || "",
    execution_proof: review.executionProof || {},
    findings: review.findings || [],
    next_steps: review.nextSteps || [],
    progress_lines: review.progressLines || [],
    critic_run_id: runId
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
  const resolution = submitResult?.resolution || {};
  completeCriticRun(cwd, runId, {
    provider: review.provider || "codex",
    verdict: resolution.verdict || review.verdict,
    summary: review.summary,
    detail: review.detail,
    artifactPath: "",
    fingerprint,
    reviewId: submitResult?.id,
    fallback: "",
    error: (resolution.verdict || review.verdict) === "CRITIC_UNAVAILABLE" ? review.detail : "",
    metrics: {
      try_again_streak: resolution.try_again_streak || 0,
      retry_limit: resolution.retry_limit || 0,
      repeated_fingerprint_streak: resolution.repeated_fingerprint_streak || 0,
      escalated: Boolean(resolution.escalated),
      escalation_reason: resolution.escalation_reason || ""
    }
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
