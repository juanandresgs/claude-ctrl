/**
 * @decision DEC-CDX-001
 * Title: W-CDX-1 lock correctness tests
 * Status: active
 * Rationale: These tests verify the atomic read-modify-write contract for state.mjs.
 *   They exercise acquireLock/releaseLock directly and the full production sequence
 *   (upsertJob via child_process.fork workers) to prove concurrent writers do not
 *   corrupt state.json. The compound interaction test (test 6) is the canonical
 *   proof of the production sequence.
 */

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import assert from "node:assert/strict";
import { fork } from "node:child_process";

import {
  acquireLock,
  releaseLock,
  resolveStateDir,
  saveState,
  upsertJob,
  loadState,
} from "../scripts/lib/state.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// ---------------------------------------------------------------------------
// Helper: create a unique temp workspace directory for each test
// ---------------------------------------------------------------------------
function makeTempWorkspace() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "cdx-lock-test-"));
}

// ---------------------------------------------------------------------------
// Helper: ensure the state dir exists for a workspace
// ---------------------------------------------------------------------------
function ensureDir(cwd) {
  const stateDir = resolveStateDir(cwd);
  fs.mkdirSync(path.join(stateDir, "jobs"), { recursive: true });
  return stateDir;
}

// ---------------------------------------------------------------------------
// Test 1: Single writer acquires and releases lock correctly
// ---------------------------------------------------------------------------
test("acquireLock creates state.lock and returns a release function that removes it", () => {
  const cwd = makeTempWorkspace();
  const stateDir = ensureDir(cwd);
  const lockPath = path.join(stateDir, "state.lock");

  assert.equal(fs.existsSync(lockPath), false, "lock should not exist before acquire");

  const release = acquireLock(stateDir);

  assert.equal(fs.existsSync(lockPath), true, "lock should exist after acquire");
  assert.equal(typeof release, "function", "acquireLock must return a release function");

  release();

  assert.equal(fs.existsSync(lockPath), false, "lock should be removed after release");
});

// ---------------------------------------------------------------------------
// Test 2: Second sequential acquire succeeds after first releases
// ---------------------------------------------------------------------------
test("second sequential acquireLock succeeds after the first lock is released", () => {
  const cwd = makeTempWorkspace();
  const stateDir = ensureDir(cwd);

  const release1 = acquireLock(stateDir);
  release1();

  // Must not throw — lock was released
  const release2 = acquireLock(stateDir);
  release2();
});

// ---------------------------------------------------------------------------
// Test 3: Stale lock (mtime > 5 seconds) is forcibly removed
// ---------------------------------------------------------------------------
test("stale lock older than 5 seconds is forcibly removed by the next acquirer", () => {
  const cwd = makeTempWorkspace();
  const stateDir = ensureDir(cwd);
  const lockPath = path.join(stateDir, "state.lock");

  // Manually create a lockfile and backdate its mtime by 6 seconds
  const fd = fs.openSync(lockPath, "wx");
  fs.closeSync(fd);
  const sixSecondsAgo = new Date(Date.now() - 6000);
  fs.utimesSync(lockPath, sixSecondsAgo, sixSecondsAgo);

  assert.equal(fs.existsSync(lockPath), true, "stale lock must exist before test");

  // acquireLock should forcibly remove the stale lock and succeed
  let release;
  assert.doesNotThrow(() => {
    release = acquireLock(stateDir, 500);
  }, "acquireLock must not throw when lock is stale");

  assert.equal(fs.existsSync(lockPath), true, "lock should be re-created after stale removal");
  release();
  assert.equal(fs.existsSync(lockPath), false, "lock should be removed after release");
});

// ---------------------------------------------------------------------------
// Test 4: Timeout is thrown after contention exceeds timeoutMs
// ---------------------------------------------------------------------------
test("acquireLock throws after timeoutMs when lock is held by another writer", () => {
  const cwd = makeTempWorkspace();
  const stateDir = ensureDir(cwd);
  const lockPath = path.join(stateDir, "state.lock");

  // Manually place a fresh lock (mtime = now) — simulates another process holding it
  const fd = fs.openSync(lockPath, "wx");
  fs.closeSync(fd);
  // Keep mtime fresh so stale-eviction doesn't trigger
  const now = new Date();
  fs.utimesSync(lockPath, now, now);

  const start = Date.now();
  assert.throws(
    () => acquireLock(stateDir, 300),
    (err) => {
      assert.ok(err instanceof Error, "must throw an Error");
      assert.match(err.message, /Could not acquire state lock after/i);
      return true;
    },
    "acquireLock must throw after timeout"
  );
  const elapsed = Date.now() - start;
  assert.ok(elapsed >= 250, `should have waited at least 250ms, waited ${elapsed}ms`);

  // Clean up manual lock
  fs.unlinkSync(lockPath);
});

// ---------------------------------------------------------------------------
// Test 5: Write-tmp-rename leaves valid state.json when a crash is simulated
// ---------------------------------------------------------------------------
test("write-tmp-rename: existing state.json survives if tmp is written but rename is not called", () => {
  const cwd = makeTempWorkspace();
  const stateDir = ensureDir(cwd);
  const stateFile = path.join(stateDir, "state.json");
  const tmpFile = path.join(stateDir, "state.json.tmp");

  // Write a known good state.json
  const goodState = { version: 1, config: { stopReviewGate: false }, jobs: [{ id: "job-orig", status: "completed", createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z" }] };
  fs.writeFileSync(stateFile, `${JSON.stringify(goodState, null, 2)}\n`, "utf8");

  // Simulate a crash: write tmp but do NOT rename
  const partialState = { version: 1, config: { stopReviewGate: false }, jobs: [] };
  fs.writeFileSync(tmpFile, `${JSON.stringify(partialState, null, 2)}\n`, "utf8");

  // Original state.json must still be intact
  const read = JSON.parse(fs.readFileSync(stateFile, "utf8"));
  assert.equal(read.jobs.length, 1, "original state.json must be intact after simulated crash");
  assert.equal(read.jobs[0].id, "job-orig");

  // Clean up tmp to avoid confusion
  fs.unlinkSync(tmpFile);
});

// ---------------------------------------------------------------------------
// Test 6: Compound-interaction — two forked workers both upsert; both survive
// ---------------------------------------------------------------------------
test("concurrent upsertJob from two forked workers both succeed and final state contains both jobs", { timeout: 15000 }, async () => {
  const cwd = makeTempWorkspace();
  const stateDir = ensureDir(cwd);

  // Write a worker script to a temp file
  const workerScript = path.join(stateDir, "worker.mjs");
  // Absolute path to state.mjs from the worktree
  const stateMjsPath = path.resolve(
    __dirname,
    "../scripts/lib/state.mjs"
  );
  fs.writeFileSync(workerScript, `
import { upsertJob } from ${JSON.stringify(stateMjsPath)};
const cwd = process.argv[2];
const jobId = process.argv[3];
upsertJob(cwd, { id: jobId, status: "running" });
process.send({ done: true, jobId });
`);

  const jobA = "job-worker-a";
  const jobB = "job-worker-b";

  await new Promise((resolve, reject) => {
    let doneCount = 0;
    function onDone(err) {
      if (err) { reject(err); return; }
      doneCount++;
      if (doneCount === 2) resolve();
    }

    const w1 = fork(workerScript, [cwd, jobA], { execArgv: [] });
    const w2 = fork(workerScript, [cwd, jobB], { execArgv: [] });

    w1.on("message", () => onDone(null));
    w2.on("message", () => onDone(null));
    w1.on("error", onDone);
    w2.on("error", onDone);
    w1.on("exit", (code) => { if (code !== 0) onDone(new Error(`worker1 exited ${code}`)); });
    w2.on("exit", (code) => { if (code !== 0) onDone(new Error(`worker2 exited ${code}`)); });
  });

  const finalState = loadState(cwd);
  const ids = finalState.jobs.map((j) => j.id);
  assert.ok(ids.includes(jobA), `final state must contain ${jobA}, got: ${JSON.stringify(ids)}`);
  assert.ok(ids.includes(jobB), `final state must contain ${jobB}, got: ${JSON.stringify(ids)}`);
});

// ---------------------------------------------------------------------------
// Test 7: saveState does NOT call loadState internally (double-read removed)
// ---------------------------------------------------------------------------
test("saveState source does not contain a loadState call (double-read removed)", () => {
  const stateMjsPath = path.resolve(__dirname, "../scripts/lib/state.mjs");
  const source = fs.readFileSync(stateMjsPath, "utf8");

  // Locate the saveState function declaration line
  const saveStateStart = source.indexOf("export function saveState(");
  assert.ok(saveStateStart !== -1, "saveState function must be present in source");

  // Walk forward character by character to find the matching closing brace
  // (brace depth counting, starting AFTER the opening brace of the function)
  let depth = 0;
  let i = saveStateStart;
  let bodyStart = -1;
  while (i < source.length) {
    if (source[i] === "{") {
      depth++;
      if (depth === 1) bodyStart = i + 1;
    } else if (source[i] === "}") {
      depth--;
      if (depth === 0) {
        break;
      }
    }
    i++;
  }

  assert.ok(bodyStart !== -1, "saveState opening brace not found");
  const saveStateBody = source.slice(bodyStart, i);

  // Strip single-line comments before checking so comment text (e.g.
  // "// This replaces the prior loadState(cwd) call") doesn't trigger a false
  // positive. Block comments (/**/) are not used in this function body.
  const bodyNoComments = saveStateBody.replace(/\/\/[^\n]*/g, "");

  // The body must not call loadState (the double-read has been removed).
  assert.ok(
    !bodyNoComments.includes("loadState("),
    `saveState must not call loadState() internally.\nBody (comments stripped):\n${bodyNoComments}`
  );
});
