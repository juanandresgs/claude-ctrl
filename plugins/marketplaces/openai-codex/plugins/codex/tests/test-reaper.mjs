/**
 * @decision DEC-CDX-002
 * Title: W-CDX-2 stale task reaper tests
 * Status: active
 * Rationale: These tests verify that isProcessAlive/reapStaleJobs correctly detect
 *   and mark as "failed" any job whose status is "running" or "queued" but whose
 *   PID no longer exists on the system. The compound-interaction test (test 7)
 *   exercises the full production sequence: create a job with a dead PID, call
 *   listJobs(), receive the reaped (failed) job back — proving transparent reaping
 *   for all consumers without any caller-side changes.
 *
 *   Conservative assumptions: EPERM (permission denied) is treated as alive; a job
 *   missing a pid field is skipped; only "running" and "queued" statuses are reaped.
 */

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import assert from "node:assert/strict";

import {
  isProcessAlive,
  reapStaleJobs,
  listJobs,
  upsertJob,
  loadState,
  writeJobFile,
  readJobFile,
  resolveJobFile,
  generateJobId,
} from "../scripts/lib/state.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// ---------------------------------------------------------------------------
// Helper: create a unique temp workspace directory for each test
// ---------------------------------------------------------------------------
function makeTempWorkspace() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "cdx-reaper-test-"));
}

// ---------------------------------------------------------------------------
// Helper: find a PID guaranteed to be dead on this machine.
// Scans downward from 99999; on any POSIX system, at least one PID in the
// range [90000, 99999] will be absent. Throws if none found (extremely unlikely).
// ---------------------------------------------------------------------------
function findDeadPid() {
  for (let pid = 99999; pid > 90000; pid--) {
    try {
      process.kill(pid, 0);
    } catch (e) {
      if (e.code === "ESRCH") return pid;
    }
  }
  throw new Error("Could not find a dead PID for testing — all PIDs 90001–99999 appear to be live");
}

// ---------------------------------------------------------------------------
// Test 1: Dead PID reaped — running job with non-existent PID becomes failed
// ---------------------------------------------------------------------------
test("dead PID running job is reaped to failed with correct errorMessage", () => {
  const cwd = makeTempWorkspace();
  const deadPid = findDeadPid();
  const jobId = generateJobId("test");

  upsertJob(cwd, { id: jobId, status: "running", phase: "running", pid: deadPid });

  const reaped = reapStaleJobs(cwd);

  assert.equal(reaped.length, 1, "exactly one job should be reaped");
  assert.equal(reaped[0].id, jobId);
  assert.equal(reaped[0].status, "failed");
  assert.equal(reaped[0].phase, "failed");
  assert.equal(reaped[0].pid, null);
  assert.ok(
    reaped[0].errorMessage.includes(String(deadPid)),
    `errorMessage must mention the dead PID; got: ${reaped[0].errorMessage}`
  );
  assert.ok(reaped[0].completedAt, "completedAt must be set on reaped job");

  // Verify persisted state also shows failed
  const persisted = loadState(cwd);
  const persistedJob = persisted.jobs.find((j) => j.id === jobId);
  assert.ok(persistedJob, "job must still be in persisted state");
  assert.equal(persistedJob.status, "failed");
});

// ---------------------------------------------------------------------------
// Test 2: Alive PID not reaped — job with current process PID stays running
// ---------------------------------------------------------------------------
test("alive PID running job is not reaped", () => {
  const cwd = makeTempWorkspace();
  const jobId = generateJobId("test");

  upsertJob(cwd, { id: jobId, status: "running", phase: "running", pid: process.pid });

  const reaped = reapStaleJobs(cwd);

  assert.equal(reaped.length, 0, "no jobs should be reaped when PID is alive");

  const persisted = loadState(cwd);
  const persistedJob = persisted.jobs.find((j) => j.id === jobId);
  assert.equal(persistedJob.status, "running", "alive-PID job must remain running");
});

// ---------------------------------------------------------------------------
// Test 3: No PID field — legacy job record without pid is not reaped
// ---------------------------------------------------------------------------
test("job without pid field is not reaped (legacy record)", () => {
  const cwd = makeTempWorkspace();
  const jobId = generateJobId("test");

  // Explicitly omit pid field
  upsertJob(cwd, { id: jobId, status: "running", phase: "running" });

  const reaped = reapStaleJobs(cwd);

  assert.equal(reaped.length, 0, "job without pid field must not be reaped");

  const persisted = loadState(cwd);
  const persistedJob = persisted.jobs.find((j) => j.id === jobId);
  assert.equal(persistedJob.status, "running", "no-pid job must remain running");
});

// ---------------------------------------------------------------------------
// Test 4: Completed job with dead PID is not reaped
// ---------------------------------------------------------------------------
test("completed job with dead PID is not reaped", () => {
  const cwd = makeTempWorkspace();
  const deadPid = findDeadPid();
  const jobId = generateJobId("test");

  upsertJob(cwd, { id: jobId, status: "completed", phase: "done", pid: deadPid });

  const reaped = reapStaleJobs(cwd);

  assert.equal(reaped.length, 0, "completed job must not be reaped even with dead PID");

  const persisted = loadState(cwd);
  const persistedJob = persisted.jobs.find((j) => j.id === jobId);
  assert.equal(persistedJob.status, "completed");
});

// ---------------------------------------------------------------------------
// Test 5: Queued job with dead PID is reaped
// ---------------------------------------------------------------------------
test("queued job with dead PID is reaped to failed", () => {
  const cwd = makeTempWorkspace();
  const deadPid = findDeadPid();
  const jobId = generateJobId("test");

  upsertJob(cwd, { id: jobId, status: "queued", phase: "queued", pid: deadPid });

  const reaped = reapStaleJobs(cwd);

  assert.equal(reaped.length, 1, "queued job with dead PID must be reaped");
  assert.equal(reaped[0].status, "failed");

  const persisted = loadState(cwd);
  const persistedJob = persisted.jobs.find((j) => j.id === jobId);
  assert.equal(persistedJob.status, "failed");
});

// ---------------------------------------------------------------------------
// Test 6: Job detail file updated — reaper merges failed fields into <job-id>.json
// ---------------------------------------------------------------------------
test("job detail file is updated when job is reaped", () => {
  const cwd = makeTempWorkspace();
  const deadPid = findDeadPid();
  const jobId = generateJobId("test");

  // Create state entry
  upsertJob(cwd, { id: jobId, status: "running", phase: "running", pid: deadPid });

  // Create the detail file (as job-control.mjs would)
  const detailPayload = { id: jobId, status: "running", phase: "running", pid: deadPid, model: "gpt-4o" };
  writeJobFile(cwd, jobId, detailPayload);

  reapStaleJobs(cwd);

  // Verify the detail file was updated
  const detailFile = resolveJobFile(cwd, jobId);
  assert.ok(fs.existsSync(detailFile), "detail file must still exist after reaping");
  const updatedDetail = readJobFile(detailFile);
  assert.equal(updatedDetail.status, "failed", "detail file status must be failed");
  assert.equal(updatedDetail.phase, "failed", "detail file phase must be failed");
  assert.equal(updatedDetail.pid, null, "detail file pid must be null");
  assert.ok(updatedDetail.errorMessage, "detail file must have errorMessage");
  assert.ok(updatedDetail.completedAt, "detail file must have completedAt");
  // Preserve existing fields
  assert.equal(updatedDetail.model, "gpt-4o", "detail file must preserve existing fields");
});

// ---------------------------------------------------------------------------
// Test 7: listJobs returns reaped state — compound interaction test
//   Production sequence: dead-PID job created -> listJobs() called -> job is failed
//   This exercises the full path: upsertJob -> disk persist -> listJobs ->
//   reapStaleJobs -> updateState (lock) -> loadState -> return failed jobs
// ---------------------------------------------------------------------------
test("listJobs transparently reaps dead-PID jobs and returns updated state", () => {
  const cwd = makeTempWorkspace();
  const deadPid = findDeadPid();
  const jobId = generateJobId("test");

  // Simulate a job that was recorded as running with a PID that has since died
  upsertJob(cwd, { id: jobId, status: "running", phase: "running", pid: deadPid });

  // The production call: listJobs triggers reapStaleJobs internally
  const jobs = listJobs(cwd);

  const job = jobs.find((j) => j.id === jobId);
  assert.ok(job, "job must be present in listJobs output");
  assert.equal(job.status, "failed", "listJobs must return the reaped (failed) job");
  assert.equal(job.pid, null, "listJobs must return null pid after reaping");
  assert.ok(job.errorMessage, "listJobs must return errorMessage on reaped job");
});

// ---------------------------------------------------------------------------
// Test 8: Multiple dead jobs all reaped in one pass
// ---------------------------------------------------------------------------
test("multiple running jobs with dead PIDs are all reaped", () => {
  const cwd = makeTempWorkspace();

  // Find 3 distinct dead PIDs
  const deadPids = [];
  for (let pid = 99999; pid > 90000 && deadPids.length < 3; pid--) {
    try {
      process.kill(pid, 0);
    } catch (e) {
      if (e.code === "ESRCH") deadPids.push(pid);
    }
  }
  assert.equal(deadPids.length, 3, "must find at least 3 dead PIDs for this test");

  const jobIds = deadPids.map((pid, i) => {
    const id = generateJobId(`test-multi-${i}`);
    upsertJob(cwd, { id, status: "running", phase: "running", pid });
    return id;
  });

  const reaped = reapStaleJobs(cwd);

  assert.equal(reaped.length, 3, "all 3 dead-PID jobs must be reaped");
  const reapedIds = reaped.map((j) => j.id);
  for (const id of jobIds) {
    assert.ok(reapedIds.includes(id), `job ${id} must be in reaped list`);
  }

  const persisted = loadState(cwd);
  for (const id of jobIds) {
    const j = persisted.jobs.find((job) => job.id === id);
    assert.equal(j.status, "failed", `persisted job ${id} must be failed`);
  }
});

// ---------------------------------------------------------------------------
// Test 9: isProcessAlive — direct unit test of the sentinel function
// ---------------------------------------------------------------------------
test("isProcessAlive returns true for current process and false for non-existent PID", () => {
  // Current process is definitely alive
  assert.equal(isProcessAlive(process.pid), true, "isProcessAlive(process.pid) must return true");

  // A guaranteed-dead PID
  const deadPid = findDeadPid();
  assert.equal(isProcessAlive(deadPid), false, `isProcessAlive(${deadPid}) must return false for dead PID`);

  // PID 0 sends signal to process group — may or may not be ESRCH but should not throw
  // We just verify it returns a boolean
  const result = isProcessAlive(0);
  assert.equal(typeof result, "boolean", "isProcessAlive must always return a boolean");
});
