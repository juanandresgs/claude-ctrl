/**
 * @decision DEC-CDX-006
 * Title: W-CDX-3 broker fallback hardening tests
 * Status: active
 * Rationale: These tests verify isRetriableBrokerError (pure function) and
 *   withAppServer (integration via test seams). The compound-interaction tests
 *   (tests 7, 9, 10) exercise the real production sequence: broker connect/fn
 *   fails, withAppServer detects retriability, emits progress, connects direct,
 *   replays fn() — proving the full fallback control flow including dual-failure
 *   error shape and connect-phase failure detection.
 *
 *   Three new cases (tests 9-11) cover Codex review findings:
 *   - Finding 1: brokerRequested computed from loadBrokerSession, not just env var
 *   - Finding 2: direct-connect failure inside try/catch produces dual-failure error
 *   - Finding 3: clean-close message-only error triggers retry
 *
 *   Test seam pattern: _setConnectFn / _setLoadBrokerSessionFn allow injection
 *   without spawning real processes. All tests call _resetConnectFn and
 *   _resetLoadBrokerSessionFn in their finally blocks to prevent state leakage.
 */

import test from "node:test";
import assert from "node:assert/strict";

import {
  isRetriableBrokerError,
  withAppServer,
  _setConnectFn,
  _resetConnectFn,
  _setLoadBrokerSessionFn,
  _resetLoadBrokerSessionFn,
} from "../scripts/lib/codex.mjs";

// ---------------------------------------------------------------------------
// Helper: build a minimal mock client
// ---------------------------------------------------------------------------
function makeMockClient(transport = "broker", opts = {}) {
  return {
    transport,
    stderr: "",
    _closed: false,
    setNotificationHandler() {},
    async request() { return opts.requestResult ?? {}; },
    async close() { this._closed = true; },
  };
}

// ---------------------------------------------------------------------------
// Tests 1-6: isRetriableBrokerError — pure function, no I/O
// ---------------------------------------------------------------------------

test("1: broker BUSY rpcCode is retriable", () => {
  const client = makeMockClient("broker");
  const error = Object.assign(new Error("busy"), { rpcCode: -32001 });
  assert.equal(isRetriableBrokerError(error, client), true);
});

test("2: ECONNREFUSED is retriable regardless of client transport", () => {
  const error = Object.assign(new Error("refused"), { code: "ECONNREFUSED" });
  assert.equal(isRetriableBrokerError(error, null), true);
});

test("3: ECONNRESET is retriable", () => {
  const error = Object.assign(new Error("reset"), { code: "ECONNRESET" });
  assert.equal(isRetriableBrokerError(error, null), true);
});

test("4: EPIPE is retriable", () => {
  const error = Object.assign(new Error("pipe"), { code: "EPIPE" });
  assert.equal(isRetriableBrokerError(error, null), true);
});

test("5: ERR_SOCKET_CLOSED is retriable", () => {
  const error = Object.assign(new Error("socket closed"), { code: "ERR_SOCKET_CLOSED" });
  assert.equal(isRetriableBrokerError(error, null), true);
});

test("6: ETIMEOUT is NOT retriable", () => {
  const client = makeMockClient("broker");
  const error = Object.assign(new Error("timeout"), { code: "ETIMEOUT" });
  assert.equal(isRetriableBrokerError(error, client), false);
});

test("11: clean-close message-only error is retriable (Finding 3)", () => {
  // No .code property — this is the handleExit() clean-close path from
  // app-server.mjs:171: new Error("codex app-server connection closed.")
  const error = new Error("codex app-server connection closed.");
  assert.equal(isRetriableBrokerError(error, null), true);
});

// ---------------------------------------------------------------------------
// Tests 7-10: withAppServer integration via test seams
// ---------------------------------------------------------------------------

test("7: broker BUSY triggers retry and returns direct result", async () => {
  const brokerClient = makeMockClient("broker");
  let callCount = 0;

  _setConnectFn(async (_cwd, opts) => {
    callCount++;
    if (!opts?.disableBroker) {
      return brokerClient;
    }
    return makeMockClient("direct");
  });
  _setLoadBrokerSessionFn(() => null);

  let fnCallCount = 0;
  try {
    // Set BROKER_ENDPOINT_ENV so brokerRequested is true
    process.env["CODEX_COMPANION_APP_SERVER_ENDPOINT"] = "http://localhost:9999";

    const result = await withAppServer("/fake/cwd", async (client) => {
      fnCallCount++;
      if (client.transport === "broker") {
        const err = Object.assign(new Error("busy"), { rpcCode: -32001 });
        throw err;
      }
      return "direct-result";
    });

    assert.equal(result, "direct-result");
    assert.equal(callCount, 2, "connect called twice: once broker, once direct");
    assert.equal(fnCallCount, 2, "fn called twice: once for broker attempt, once for direct");
  } finally {
    delete process.env["CODEX_COMPANION_APP_SERVER_ENDPOINT"];
    _resetConnectFn();
    _resetLoadBrokerSessionFn();
  }
});

test("8: fallback emits progress on broker BUSY", async () => {
  _setConnectFn(async (_cwd, opts) => {
    if (!opts?.disableBroker) {
      return makeMockClient("broker");
    }
    return makeMockClient("direct");
  });
  _setLoadBrokerSessionFn(() => null);

  const progressMessages = [];
  try {
    process.env["CODEX_COMPANION_APP_SERVER_ENDPOINT"] = "http://localhost:9999";

    await withAppServer(
      "/fake/cwd",
      async (client) => {
        if (client.transport === "broker") {
          throw Object.assign(new Error("busy"), { rpcCode: -32001 });
        }
        return "ok";
      },
      {
        onProgress: (msg) => {
          const text = typeof msg === "string" ? msg : msg.message;
          progressMessages.push(text);
        }
      }
    );

    const fallbackMsg = progressMessages.find((m) => m.includes("Broker busy or unavailable"));
    assert.ok(fallbackMsg, `Expected fallback progress message, got: ${JSON.stringify(progressMessages)}`);
  } finally {
    delete process.env["CODEX_COMPANION_APP_SERVER_ENDPOINT"];
    _resetConnectFn();
    _resetLoadBrokerSessionFn();
  }
});

test("9: connect-phase failure triggers retry via loadBrokerSession (Finding 1)", async () => {
  // BROKER_ENDPOINT_ENV is NOT set. brokerRequested must come from _loadBrokerSessionFn.
  let connectCallCount = 0;
  _setConnectFn(async (_cwd, opts) => {
    connectCallCount++;
    if (!opts?.disableBroker) {
      throw Object.assign(new Error("refused"), { code: "ECONNREFUSED" });
    }
    return makeMockClient("direct");
  });
  // Return non-null session to make brokerRequested=true even without env var
  _setLoadBrokerSessionFn(() => ({ endpoint: "http://localhost:9999" }));

  try {
    const result = await withAppServer("/fake/cwd", async (client) => {
      assert.equal(client.transport, "direct", "fn must receive direct client");
      return "from-direct";
    });

    assert.equal(result, "from-direct");
    assert.equal(connectCallCount, 2, "connect called twice: failed broker + successful direct");
  } finally {
    _resetConnectFn();
    _resetLoadBrokerSessionFn();
  }
});

test("10: direct-connect failure produces dual-failure error (Finding 2)", async () => {
  _setConnectFn(async (_cwd, opts) => {
    if (!opts?.disableBroker) {
      // Return broker client whose fn call fails
      return makeMockClient("broker");
    }
    // Direct connect also fails
    throw Object.assign(new Error("direct refused"), { code: "ECONNREFUSED" });
  });
  _setLoadBrokerSessionFn(() => null);

  try {
    process.env["CODEX_COMPANION_APP_SERVER_ENDPOINT"] = "http://localhost:9999";

    await assert.rejects(
      () =>
        withAppServer("/fake/cwd", async (client) => {
          if (client.transport === "broker") {
            throw Object.assign(new Error("broker reset"), { code: "ECONNRESET" });
          }
          return "unreachable";
        }),
      (err) => {
        assert.ok(err.brokerError, "combined error must have .brokerError");
        assert.ok(err.directError, "combined error must have .directError");
        assert.equal(err.brokerError.code, "ECONNRESET");
        assert.equal(err.directError.code, "ECONNREFUSED");
        assert.ok(
          err.message.includes("Broker failed") && err.message.includes("direct fallback also failed"),
          `unexpected message: ${err.message}`
        );
        return true;
      }
    );
  } finally {
    delete process.env["CODEX_COMPANION_APP_SERVER_ENDPOINT"];
    _resetConnectFn();
    _resetLoadBrokerSessionFn();
  }
});
