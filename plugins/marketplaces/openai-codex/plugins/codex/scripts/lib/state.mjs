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

export function listJobs(cwd) {
  return loadState(cwd).jobs;
}

export function setConfig(cwd, key, value) {
  return updateState(cwd, (state) => {
    state.config = {
      ...state.config,
      [key]: value
    };
  });
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
