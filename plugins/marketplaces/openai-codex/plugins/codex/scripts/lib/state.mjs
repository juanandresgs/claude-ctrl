/**
 * @decision DEC-CDX-001
 * Title: Atomic state writes via O_EXCL lockfile + write-tmp-rename
 * Status: active
 * Rationale: state.json is written by multiple concurrent processes (each Codex
 *   session fork calls upsertJob). Without a lock, concurrent load-mutate-save
 *   cycles lose updates (last-writer-wins). We use:
 *     1. O_EXCL lockfile: fs.openSync('wx') is atomic on POSIX; only one opener
 *        wins. Stale locks (mtime > 5s) are forcibly evicted.
 *     2. Write-tmp-rename: state.json.tmp is written first; fs.renameSync is
 *        atomic on POSIX, so a crash between write and rename leaves the previous
 *        state.json intact.
 *   External deps are forbidden (spec). Busy-wait uses Atomics.wait on a
 *   SharedArrayBuffer rather than setTimeout to avoid yielding the event loop
 *   between lock-check iterations.
 *
 *   The double-read bug in the original saveState (calling loadState a second
 *   time to get previousJobs for pruning) is removed. previousJobs is now
 *   derived from state.jobs before pruning — no second disk read.
 *
 * @decision DEC-CDX-002
 * Title: Stale task reaper — transparent PID liveness check inside listJobs
 * Status: active
 * Rationale: When a Codex session process dies unexpectedly (kill -9, OOM,
 *   machine sleep) its job record stays "running" or "queued" forever. The UI
 *   then shows phantom in-progress jobs. The reaper fixes this transparently:
 *   listJobs() calls reapStaleJobs() before returning, so every consumer gets
 *   fresh state without any caller-side changes.
 *
 *   Design choices:
 *     - process.kill(pid, 0): POSIX standard for liveness probe — no signal sent.
 *     - ESRCH = dead; EPERM = alive (process exists, we lack permission).
 *     - Conservative default: any unexpected error → assume alive (no spurious reap).
 *     - Only "running" and "queued" jobs with a finite numeric pid are candidates.
 *       Jobs without a pid field (legacy records) are skipped.
 *     - Reaping writes through updateState() to preserve the W-CDX-1 atomic lock.
 *     - The job detail file (<job-id>.json) is updated in the same reap pass so
 *       readers of the detail file see consistent "failed" state.
 *     - reapStaleJobs() returns the array of reaped job objects for caller logging.
 */

import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import { resolveWorkspaceRoot } from "./workspace.mjs";

const STATE_VERSION = 1;
const PLUGIN_DATA_ENV = "CLAUDE_PLUGIN_DATA";
const FALLBACK_STATE_ROOT_DIR = path.join(os.tmpdir(), "codex-companion");
const STATE_FILE_NAME = "state.json";
const LOCK_FILE_NAME = "state.lock";
const JOBS_DIR_NAME = "jobs";
const MAX_JOBS = 50;

// Stale-lock threshold: if a lockfile is older than this, it is considered
// abandoned (process crashed without releasing) and will be forcibly evicted.
const LOCK_STALE_MS = 5000;

function nowIso() {
  return new Date().toISOString();
}

function defaultState() {
  return {
    version: STATE_VERSION,
    config: {
      stopReviewGate: false
    },
    jobs: []
  };
}

export function resolveStateDir(cwd) {
  const workspaceRoot = resolveWorkspaceRoot(cwd);
  let canonicalWorkspaceRoot = workspaceRoot;
  try {
    canonicalWorkspaceRoot = fs.realpathSync.native(workspaceRoot);
  } catch {
    canonicalWorkspaceRoot = workspaceRoot;
  }

  const slugSource = path.basename(workspaceRoot) || "workspace";
  const slug = slugSource.replace(/[^a-zA-Z0-9._-]+/g, "-").replace(/^-+|-+$/g, "") || "workspace";
  const hash = createHash("sha256").update(canonicalWorkspaceRoot).digest("hex").slice(0, 16);
  const pluginDataDir = process.env[PLUGIN_DATA_ENV];
  const stateRoot = pluginDataDir ? path.join(pluginDataDir, "state") : FALLBACK_STATE_ROOT_DIR;
  return path.join(stateRoot, `${slug}-${hash}`);
}

export function resolveStateFile(cwd) {
  return path.join(resolveStateDir(cwd), STATE_FILE_NAME);
}

export function resolveJobsDir(cwd) {
  return path.join(resolveStateDir(cwd), JOBS_DIR_NAME);
}

export function ensureStateDir(cwd) {
  fs.mkdirSync(resolveJobsDir(cwd), { recursive: true });
}

export function loadState(cwd) {
  const stateFile = resolveStateFile(cwd);
  if (!fs.existsSync(stateFile)) {
    return defaultState();
  }

  try {
    const parsed = JSON.parse(fs.readFileSync(stateFile, "utf8"));
    return {
      ...defaultState(),
      ...parsed,
      config: {
        ...defaultState().config,
        ...(parsed.config ?? {})
      },
      jobs: Array.isArray(parsed.jobs) ? parsed.jobs : []
    };
  } catch {
    return defaultState();
  }
}

// ---------------------------------------------------------------------------
// Lock primitives
// ---------------------------------------------------------------------------

/**
 * Synchronous busy-wait sleep using Atomics.wait on a SharedArrayBuffer.
 * This avoids yielding the event loop (setTimeout polling is forbidden by spec).
 *
 * @param {number} ms - milliseconds to sleep
 */
function syncSleep(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

/**
 * Attempt to create a lockfile using O_EXCL (exclusive create).
 * Returns true on success, false if the lock already exists.
 *
 * @param {string} lockPath
 * @returns {boolean}
 */
function tryCreateLock(lockPath) {
  try {
    const fd = fs.openSync(lockPath, "wx");
    fs.closeSync(fd);
    return true;
  } catch (err) {
    if (err.code === "EEXIST") {
      return false;
    }
    throw err;
  }
}

/**
 * Remove a lockfile, ignoring ENOENT (already gone).
 *
 * @param {string} lockPath
 */
export function releaseLock(lockPath) {
  try {
    fs.unlinkSync(lockPath);
  } catch (err) {
    if (err.code !== "ENOENT") {
      throw err;
    }
  }
}

/**
 * Acquire an exclusive lock on the state directory.
 *
 * Strategy:
 *   - Try fs.openSync(lockPath, 'wx') — atomic O_EXCL create.
 *   - On EEXIST: check the lockfile's mtime. If older than LOCK_STALE_MS,
 *     the previous owner crashed; unlink and retry immediately.
 *   - Otherwise: exponential backoff (10ms, 20ms, 40ms, …) and retry.
 *   - If timeoutMs elapses without acquiring: throw.
 *
 * Returns a release() function that removes the lockfile.
 *
 * @param {string} stateDir - directory containing state.json
 * @param {number} [timeoutMs=2000] - how long to wait before giving up
 * @returns {() => void} release function
 */
export function acquireLock(stateDir, timeoutMs = 2000) {
  const lockPath = path.join(stateDir, LOCK_FILE_NAME);
  const deadline = Date.now() + timeoutMs;
  let delay = 10; // initial backoff ms

  // eslint-disable-next-line no-constant-condition
  while (true) {
    if (tryCreateLock(lockPath)) {
      // Lock acquired — return a release closure
      return () => releaseLock(lockPath);
    }

    // Lock exists: check if it is stale
    try {
      const stat = fs.statSync(lockPath);
      const age = Date.now() - stat.mtimeMs;
      if (age > LOCK_STALE_MS) {
        // Stale: evict and retry immediately (no sleep)
        try {
          fs.unlinkSync(lockPath);
        } catch (unlinkErr) {
          // Another process may have evicted it first — that's fine
          if (unlinkErr.code !== "ENOENT") {
            throw unlinkErr;
          }
        }
        continue; // retry tryCreateLock immediately
      }
    } catch (statErr) {
      // Lock disappeared between EEXIST and stat — retry immediately
      if (statErr.code === "ENOENT") {
        continue;
      }
      throw statErr;
    }

    // Check timeout BEFORE sleeping
    const remaining = deadline - Date.now();
    if (remaining <= 0) {
      throw new Error(
        `Could not acquire state lock after ${timeoutMs}ms: ${lockPath}`
      );
    }

    // Sleep for min(delay, remaining) then double the backoff
    const sleepFor = Math.min(delay, remaining);
    syncSleep(sleepFor);
    delay = Math.min(delay * 2, 500); // cap at 500ms per interval

    // Re-check timeout after sleeping
    if (Date.now() >= deadline) {
      throw new Error(
        `Could not acquire state lock after ${timeoutMs}ms: ${lockPath}`
      );
    }
  }
}

// ---------------------------------------------------------------------------
// State persistence
// ---------------------------------------------------------------------------

function pruneJobs(jobs) {
  return [...jobs]
    .sort((left, right) => String(right.updatedAt ?? "").localeCompare(String(left.updatedAt ?? "")))
    .slice(0, MAX_JOBS);
}

function removeFileIfExists(filePath) {
  if (filePath && fs.existsSync(filePath)) {
    fs.unlinkSync(filePath);
  }
}

/**
 * Persist state to disk using write-tmp-rename for crash safety.
 *
 * The double-read bug from the original implementation is removed: we no
 * longer call loadState() here. Instead, previousJobs is derived directly
 * from state.jobs before pruning — the caller already holds the full
 * in-memory state (loaded once by updateState under the lock).
 *
 * Write sequence:
 *   1. Compute nextJobs = pruneJobs(state.jobs)
 *   2. Identify dropped jobs = state.jobs ids not in nextJobs
 *   3. Remove artifact files for dropped jobs
 *   4. Write JSON to state.json.tmp
 *   5. fs.renameSync(tmp -> state.json)  <- atomic on POSIX
 *
 * @param {string} cwd
 * @param {{ version?: number, config?: object, jobs?: object[] }} state
 * @returns {{ version: number, config: object, jobs: object[] }}
 */
export function saveState(cwd, state) {
  ensureStateDir(cwd);

  // All jobs before pruning — used to identify dropped artifacts.
  // This replaces the prior loadState(cwd) call (the double-read bug).
  const previousJobs = state.jobs ?? [];
  const nextJobs = pruneJobs(previousJobs);

  const nextState = {
    version: STATE_VERSION,
    config: {
      ...defaultState().config,
      ...(state.config ?? {})
    },
    jobs: nextJobs
  };

  const retainedIds = new Set(nextJobs.map((job) => job.id));
  for (const job of previousJobs) {
    if (retainedIds.has(job.id)) {
      continue;
    }
    removeJobFile(resolveJobFile(cwd, job.id));
    removeFileIfExists(job.logFile);
  }

  const stateFile = resolveStateFile(cwd);
  const tmpFile = `${stateFile}.tmp`;

  fs.writeFileSync(tmpFile, `${JSON.stringify(nextState, null, 2)}\n`, "utf8");
  fs.renameSync(tmpFile, stateFile);

  return nextState;
}

/**
 * Atomically read-modify-write the state file.
 *
 * Holds the O_EXCL lock for the entire load -> mutate -> save cycle so no
 * concurrent writer can interleave.
 *
 * @param {string} cwd
 * @param {(state: object) => void} mutate - mutates state in place
 * @returns {{ version: number, config: object, jobs: object[] }}
 */
export function updateState(cwd, mutate) {
  const stateDir = resolveStateDir(cwd);
  // Ensure the directory exists before attempting to create the lockfile
  fs.mkdirSync(path.join(stateDir, JOBS_DIR_NAME), { recursive: true });

  const release = acquireLock(stateDir);
  try {
    const state = loadState(cwd);
    mutate(state);
    return saveState(cwd, state);
  } finally {
    release();
  }
}

export function generateJobId(prefix = "job") {
  const random = Math.random().toString(36).slice(2, 8);
  return `${prefix}-${Date.now().toString(36)}-${random}`;
}

export function upsertJob(cwd, jobPatch) {
  return updateState(cwd, (state) => {
    const timestamp = nowIso();
    const existingIndex = state.jobs.findIndex((job) => job.id === jobPatch.id);
    if (existingIndex === -1) {
      state.jobs.unshift({
        createdAt: timestamp,
        updatedAt: timestamp,
        ...jobPatch
      });
      return;
    }
    state.jobs[existingIndex] = {
      ...state.jobs[existingIndex],
      ...jobPatch,
      updatedAt: timestamp
    };
  });
}

// ---------------------------------------------------------------------------
// Stale task reaper (W-CDX-2)
// ---------------------------------------------------------------------------

/**
 * Probe whether a process is still alive using the POSIX signal-0 trick.
 *
 * process.kill(pid, 0) does not send a signal — it only checks whether the
 * process exists and we have permission to signal it.
 *
 * Error codes:
 *   ESRCH  — no such process → dead
 *   EPERM  — process exists but we lack permission → alive (conservative)
 *   <other> — unknown error → assume alive to avoid spurious reaping
 *
 * @param {number} pid
 * @returns {boolean} true if the process is alive or existence is uncertain
 */
export function isProcessAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    if (err.code === "ESRCH") return false; // process not found
    if (err.code === "EPERM") return true;  // exists but no permission to signal
    return true; // conservative: assume alive on unknown errors
  }
}

/**
 * Scan the job list for stale jobs (status "running" or "queued" with a dead
 * PID) and mark them as "failed".
 *
 * A job is a reap candidate when ALL of the following hold:
 *   1. status is "running" or "queued"
 *   2. pid is a finite number (not null, undefined, or NaN)
 *   3. isProcessAlive(pid) returns false
 *
 * For each stale job:
 *   - Sets status, phase → "failed"
 *   - Sets pid → null
 *   - Sets errorMessage with the dead PID for auditability
 *   - Sets completedAt to now
 *
 * The job detail file (<job-id>.json) is also updated if it exists, so readers
 * of the detail file see consistent state.
 *
 * If any jobs were reaped, state is persisted via updateState() (which holds
 * the W-CDX-1 O_EXCL lock for the entire read-modify-write cycle).
 *
 * @param {string} cwd
 * @returns {object[]} array of reaped job objects (after mutation, for logging)
 */
export function reapStaleJobs(cwd) {
  const state = loadState(cwd);
  const candidates = state.jobs.filter(
    (job) =>
      (job.status === "running" || job.status === "queued") &&
      typeof job.pid === "number" &&
      Number.isFinite(job.pid) &&
      !isProcessAlive(job.pid)
  );

  if (candidates.length === 0) {
    return [];
  }

  const reapedIds = new Set(candidates.map((j) => j.id));
  const reapedJobs = [];

  updateState(cwd, (s) => {
    const timestamp = nowIso();
    for (const job of s.jobs) {
      if (!reapedIds.has(job.id)) continue;
      const originalPid = job.pid;
      job.status = "failed";
      job.phase = "failed";
      job.pid = null;
      job.errorMessage = `Process exited unexpectedly (PID ${originalPid} not found).`;
      job.completedAt = timestamp;
      job.updatedAt = timestamp;

      // Update the job detail file so readers of <job-id>.json see consistent state.
      // Errors reading/writing the detail file are intentionally non-fatal: the
      // canonical state.json is already being updated; the detail file is best-effort.
      try {
        const detailFile = resolveJobFile(cwd, job.id);
        if (fs.existsSync(detailFile)) {
          const existing = JSON.parse(fs.readFileSync(detailFile, "utf8"));
          const updated = {
            ...existing,
            status: "failed",
            phase: "failed",
            pid: null,
            errorMessage: job.errorMessage,
            completedAt: timestamp,
          };
          fs.writeFileSync(detailFile, `${JSON.stringify(updated, null, 2)}\n`, "utf8");
        }
      } catch {
        // Non-fatal: detail file update failure must not prevent state.json reaping
      }

      reapedJobs.push({ ...job });
    }
  });

  return reapedJobs;
}

export function listJobs(cwd) {
  reapStaleJobs(cwd);
  return loadState(cwd).jobs;
}

/**
 * Dual-write shim for stopReviewGate (DEC-REGULAR-STOP-REVIEW-001).
 *
 * When a caller sets the stopReviewGate key in state.json, we also propagate
 * the value to the canonical enforcement_config authority via cc-policy config
 * set. This keeps state.json as a deprecated dual-write target during the
 * transition window: new readers use enforcement_config; legacy readers that
 * still load getConfig() continue to work.
 *
 * The dual-write is best-effort: if the cc-policy CLI call fails (e.g. the
 * runtime is unavailable or the caller lacks guardian role), we log to stderr
 * but do NOT throw — the primary state.json write must not be blocked by the
 * secondary propagation.
 *
 * @param {string} cwd
 * @param {string} key
 * @param {*} value
 */
function maybePropagateToEnforcementConfig(cwd, key, value) {
  if (key !== "stopReviewGate") {
    return;
  }
  // Map state.json bool/string to enforcement_config string value.
  // "true" / true → "true"; anything else → "false".
  const canonicalValue = (value === true || value === "true") ? "true" : "false";
  // execFileSync is imported at the top of this file from "node:child_process".
  const cliPath = path.resolve(
    path.dirname(new URL(import.meta.url).pathname),
    "..", "..", "..", "..", "..", "..", "runtime", "cli.py"
  );
  const env = { ...process.env };
  if (!env.CLAUDE_POLICY_DB && env.CLAUDE_PROJECT_DIR) {
    env.CLAUDE_POLICY_DB = `${env.CLAUDE_PROJECT_DIR}/.claude/state.db`;
  }
  try {
    execFileSync(
      "python3",
      [cliPath, "config", "set", "review_gate_regular_stop", canonicalValue],
      { env, encoding: "utf8", stdio: ["pipe", "pipe", "pipe"], timeout: 5000 }
    );
  } catch {
    // Best-effort: do not block the primary state.json write (DEC-REGULAR-STOP-REVIEW-001)
    process.stderr.write(
      `[state.mjs] dual-write to enforcement_config failed for key=${key}; state.json write proceeds\n`
    );
  }
}

export function setConfig(cwd, key, value) {
  // Primary write: state.json via updateState (atomic, W-CDX-1 lock).
  const result = updateState(cwd, (state) => {
    state.config = {
      ...state.config,
      [key]: value
    };
  });
  // Secondary write: propagate stopReviewGate to the canonical enforcement_config
  // authority (DEC-REGULAR-STOP-REVIEW-001). Best-effort; never throws.
  maybePropagateToEnforcementConfig(cwd, key, value);
  return result;
}

export function getConfig(cwd) {
  return loadState(cwd).config;
}

export function writeJobFile(cwd, jobId, payload) {
  ensureStateDir(cwd);
  const jobFile = resolveJobFile(cwd, jobId);
  fs.writeFileSync(jobFile, `${JSON.stringify(payload, null, 2)}\n`, "utf8");
  return jobFile;
}

export function readJobFile(jobFile) {
  return JSON.parse(fs.readFileSync(jobFile, "utf8"));
}

function removeJobFile(jobFile) {
  if (fs.existsSync(jobFile)) {
    fs.unlinkSync(jobFile);
  }
}

export function resolveJobLogFile(cwd, jobId) {
  ensureStateDir(cwd);
  return path.join(resolveJobsDir(cwd), `${jobId}.log`);
}

export function resolveJobFile(cwd, jobId) {
  ensureStateDir(cwd);
  return path.join(resolveJobsDir(cwd), `${jobId}.json`);
}
