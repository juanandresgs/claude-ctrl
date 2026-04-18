"""Subprocess tests for the broker-PID-persist fix in ``scripts/claudex-bridge-up.sh``.

# Option A (helper extraction) rationale
The production sequence is:
  1. bridge-up.sh is invoked with --tmux-target
  2. ``_claudex_start_broker`` cleans up stale state, launches braidd via
     ``nohup node braidd.mjs --socket SOCK``, waits up to 3 s for the socket
     to appear, then writes the PID atomically to ``braidd.pid``.
  3. ``claudex-bridge-status.sh`` reads ``braidd.pid`` and emits
     ``broker_pid: <pid> (running)`` when the pid is alive.

Testing Option A: we source ``claudex-bridge-up.sh`` with the env var
``CLAUDEX_BRIDGE_UP_SOURCED_ONLY=1`` so only the function definitions are
loaded (the main body is guarded behind that flag).  We then call
``_claudex_start_broker`` directly, overriding ``node`` in PATH with a tiny
shell shim that either binds the AF_UNIX socket (happy-path) or just sleeps
without binding (failure-path).  This exercises the real shell logic without
needing bootstrap.sh, tmux, or a real Node.js binary.

Compound-interaction test (test_status_reports_running_after_bridge_up_pid_persisted):
After the broker helper writes the PID file, we invoke
``claudex-bridge-status.sh`` (read-only) and assert the status output contains
the literal ``broker_pid: <pid> (running)`` pattern.  This crosses the
bridge-up → braidd.pid → bridge-status consumer chain in one test.

@decision DEC-GS1-B-BROKER-PID-PERSIST-001
Title: bridge-up is the canonical writer for braidd.pid at launch time
Status: accepted
Rationale: See scripts/claudex-bridge-up.sh; the write happens only after
BROKER_READY=1, using atomic .tmp+mv.  watchdog is canonical at adoption time.
"""

from __future__ import annotations

import os
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_BRIDGE_UP = _REPO_ROOT / "scripts" / "claudex-bridge-up.sh"
_STATUS = _REPO_ROOT / "scripts" / "claudex-bridge-status.sh"
_COMMON = _REPO_ROOT / "scripts" / "claudex-common.sh"

pytestmark = pytest.mark.skipif(
    shutil.which("bash") is None,
    reason="claudex-bridge-up.sh requires bash",
)


# ---------------------------------------------------------------------------
# Shared fixture: fake git repo + fake BRAID_ROOT with short socket path
# ---------------------------------------------------------------------------


@pytest.fixture
def broker_env(tmp_path):
    """Create a hermetic environment for testing _claudex_start_broker.

    Layout::

        tmp_path/
          fake-repo/        <- fake git repo (CWD for sourcing)
            .claude/claudex/  <- PID_DIR (CLAUDEX_STATE_DIR)
            scripts/          <- contains claudex-common.sh symlink
        mkdtemp()/            <- fake BRAID_ROOT (short path for socket)
          runs/
            braidd.sock       <- created by fake-node on success
            braidd.pid        <- written by _claudex_start_broker on success
          braidd.mjs          <- fake file (existence check)
          fake-bin/
            node              <- fake node shim (executable)

    The fake BRAID_ROOT is placed under tempfile.mkdtemp() (not tmp_path)
    because macOS caps AF_UNIX sun_path at ~104 bytes and pytest's tmp_path
    prefix is already ~100 bytes before adding subdirectories.
    """
    fake_repo = tmp_path / "fake-repo"
    pid_dir = fake_repo / ".claude" / "claudex"
    pid_dir.mkdir(parents=True)

    # Minimal fake scripts directory so bridge-up can source claudex-common.sh
    scripts_dir = fake_repo / "scripts"
    scripts_dir.mkdir()
    # Symlink common.sh into the fake repo so source works correctly
    (scripts_dir / "claudex-common.sh").symlink_to(_COMMON)

    # Initialise a real git repo so `git rev-parse --show-toplevel` works
    subprocess.run(
        ["git", "init", "--quiet", str(fake_repo)],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "-C", str(fake_repo), "config", "user.email", "test@example.com"],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "-C", str(fake_repo), "config", "user.name", "Test"],
        check=True,
        capture_output=True,
    )

    # Short-path BRAID_ROOT to stay inside macOS AF_UNIX sun_path limit
    fake_braid = Path(tempfile.mkdtemp(prefix="cxbu-"))
    runs_dir = fake_braid / "runs"
    runs_dir.mkdir()
    # Fake braidd.mjs so the existence check in the main body passes (not
    # exercised here, but avoids surprises if the guard fires incorrectly)
    (fake_braid / "braidd.mjs").write_text("// fake\n")

    sock_path = runs_dir / "braidd.sock"
    pid_file = runs_dir / "braidd.pid"

    # fake-bin: the directory where our fake 'node' shim lives
    fake_bin = fake_braid / "fake-bin"
    fake_bin.mkdir()

    env_base = {
        **os.environ,
        "BRAID_ROOT": str(fake_braid),
        "STATE_DIR": str(runs_dir),
        "CLAUDEX_STATE_DIR": str(pid_dir),
        "BROKER_SOCK": str(sock_path),
        "BROKER_PID_FILE": str(pid_file),
        "PID_DIR": str(pid_dir),
    }

    result = {
        "repo": fake_repo,
        "braid": fake_braid,
        "runs": runs_dir,
        "pid_dir": pid_dir,
        "sock": sock_path,
        "pid_file": pid_file,
        "fake_bin": fake_bin,
        "env_base": env_base,
    }

    try:
        yield result
    finally:
        shutil.rmtree(fake_braid, ignore_errors=True)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _write_fake_node(fake_bin: Path, *, binds_socket: bool) -> Path:
    """Write a fake 'node' shim into fake_bin and make it executable.

    If binds_socket=True: the shim binds the socket path (passed as the
    argument after --socket) and sleeps, simulating a live broker.

    If binds_socket=False: the shim just sleeps without binding, simulating
    a broker that never comes up.
    """
    node_path = fake_bin / "node"
    if binds_socket:
        node_path.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "SOCK=''\n"
            "while [[ $# -gt 0 ]]; do\n"
            "  if [[ \"$1\" == '--socket' ]]; then SOCK=\"$2\"; shift 2\n"
            "  else shift; fi\n"
            "done\n"
            "if [[ -n \"$SOCK\" ]]; then\n"
            "  python3 - \"$SOCK\" <<'PY'\n"
            "import socket, sys, time\n"
            "s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)\n"
            "s.bind(sys.argv[1])\n"
            "s.listen(1)\n"
            "time.sleep(60)\n"
            "PY\n"
            "fi\n"
        )
    else:
        node_path.write_text(
            "#!/usr/bin/env bash\n"
            "# Fake node that never binds the socket (readiness-failure path)\n"
            "sleep 60\n"
        )
    node_path.chmod(0o755)
    return node_path


def _invoke_start_broker(broker_env: dict, extra_env: dict | None = None) -> subprocess.CompletedProcess:
    """Source bridge-up.sh (guard mode) in the fake repo, then call _claudex_start_broker.

    Returns the CompletedProcess so tests can inspect stdout/stderr/returncode
    and check the output variables echoed from the helper.
    """
    env = {**broker_env["env_base"]}
    if extra_env:
        env.update(extra_env)

    # Put fake-bin first in PATH so the shim overrides the real 'node'
    env["PATH"] = str(broker_env["fake_bin"]) + ":" + env.get("PATH", "/usr/bin:/bin")

    script = (
        "set -euo pipefail\n"
        f"CLAUDEX_BRIDGE_UP_SOURCED_ONLY=1 source '{_BRIDGE_UP}'\n"
        "_claudex_start_broker\n"
        # Export state so the test can observe it
        'echo "BROKER_READY=$BROKER_READY"\n'
        'echo "BROKER_PID=$BROKER_PID"\n'
    )

    return subprocess.run(
        ["bash", "-c", script],
        cwd=str(broker_env["repo"]),
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_bridge_up_persists_broker_pid_after_readiness(broker_env):
    """After a successful broker launch, braidd.pid contains the broker PID
    and that process is still alive.

    This is the primary regression gate for GS1-B-1.
    """
    _write_fake_node(broker_env["fake_bin"], binds_socket=True)

    result = _invoke_start_broker(broker_env)

    assert result.returncode == 0, (
        f"_claudex_start_broker exited non-zero.\nstdout={result.stdout}\nstderr={result.stderr}"
    )

    pid_file = broker_env["pid_file"]
    assert pid_file.exists(), (
        f"braidd.pid was not created after successful readiness.\n"
        f"stdout={result.stdout}\nstderr={result.stderr}"
    )

    raw = pid_file.read_text().strip()
    assert raw.isdigit(), f"braidd.pid contains non-numeric content: {raw!r}"
    broker_pid = int(raw)

    # The process should still be alive (it's sleeping inside fake-node)
    try:
        os.kill(broker_pid, 0)
    except ProcessLookupError:
        pytest.fail(f"broker process {broker_pid} is not alive after _claudex_start_broker succeeded")
    except PermissionError:
        pass  # alive but we can't signal it — acceptable

    # Cleanup: terminate the fake broker
    try:
        os.kill(broker_pid, 15)
    except (ProcessLookupError, PermissionError):
        pass


def test_bridge_up_does_not_persist_pid_when_readiness_fails(broker_env):
    """When the broker never binds the socket, BROKER_READY stays 0 and
    braidd.pid must NOT be written.

    Readiness wait is 6 × 0.5 s = 3 s max.  We use a fake node that sleeps
    without binding, so all 6 iterations time out.
    """
    _write_fake_node(broker_env["fake_bin"], binds_socket=False)

    result = _invoke_start_broker(broker_env)

    # The helper itself returns 0 (it sets BROKER_READY=0 and returns;
    # the caller — not tested here — would exit 1).
    # Either returncode or not matters less; what matters is the file.
    pid_file = broker_env["pid_file"]
    assert not pid_file.exists(), (
        f"braidd.pid must NOT exist when broker never became ready.\n"
        f"returncode={result.returncode}\nstdout={result.stdout}\nstderr={result.stderr}"
    )

    # BROKER_READY should be 0
    assert "BROKER_READY=0" in result.stdout, (
        f"Expected BROKER_READY=0 in output.\nstdout={result.stdout}"
    )

    # Kill the sleeping fake-node
    if "BROKER_PID=" in result.stdout:
        for line in result.stdout.splitlines():
            if line.startswith("BROKER_PID="):
                raw = line.split("=", 1)[1].strip()
                if raw.isdigit():
                    try:
                        os.kill(int(raw), 15)
                    except (ProcessLookupError, PermissionError):
                        pass


def test_status_reports_running_after_bridge_up_pid_persisted(broker_env):
    """Compound-interaction test: bridge-up writes braidd.pid, then
    claudex-bridge-status.sh reads it and emits ``broker_pid: <pid> (running)``.

    This crosses the full chain:
      bridge-up._claudex_start_broker → braidd.pid → claudex-bridge-status.sh
    """
    pytest.importorskip("shutil")
    if shutil.which("jq") is None:
        pytest.skip("claudex-bridge-status.sh requires jq")

    _write_fake_node(broker_env["fake_bin"], binds_socket=True)

    # Step 1: invoke the broker helper (writes braidd.pid)
    invoke_result = _invoke_start_broker(broker_env)
    assert invoke_result.returncode == 0, (
        f"Broker helper failed.\nstdout={invoke_result.stdout}\nstderr={invoke_result.stderr}"
    )

    pid_file = broker_env["pid_file"]
    assert pid_file.exists(), "braidd.pid not written after successful helper"

    broker_pid = int(pid_file.read_text().strip())

    # Step 2: invoke bridge-status (read-only, no modification)
    braid_root = broker_env["braid"]
    pid_dir = broker_env["pid_dir"]

    status_env = {
        **os.environ,
        "BRAID_ROOT": str(braid_root),
        "CLAUDEX_STATE_DIR": str(pid_dir),
    }
    status_result = subprocess.run(
        ["bash", str(_STATUS)],
        cwd=str(broker_env["repo"]),
        env=status_env,
        capture_output=True,
        text=True,
        timeout=20,
    )

    # The status script may fail if some optional tools are missing, but we
    # only need the broker_pid line — check it regardless of returncode.
    output = status_result.stdout + status_result.stderr

    expected = f"broker_pid: {broker_pid} (running)"
    assert expected in status_result.stdout, (
        f"Expected '{expected}' in bridge-status output.\n"
        f"stdout={status_result.stdout}\nstderr={status_result.stderr}"
    )

    # Must NOT contain false-negative patterns
    assert "socket_present (pid file missing)" not in status_result.stdout, (
        "bridge-status still emits 'pid file missing' after bridge-up wrote it"
    )
    assert "socket_present (pid file stale)" not in status_result.stdout, (
        "bridge-status reports stale pid when it should be running"
    )
    assert "broker_pid: stale" not in status_result.stdout, (
        "bridge-status reports stale broker_pid"
    )

    # Cleanup
    try:
        os.kill(broker_pid, 15)
    except (ProcessLookupError, PermissionError):
        pass


def test_bridge_up_atomic_write(broker_env):
    """The .tmp intermediate file must not survive after _claudex_start_broker
    returns, and braidd.pid must be a regular file.
    """
    _write_fake_node(broker_env["fake_bin"], binds_socket=True)

    result = _invoke_start_broker(broker_env)
    assert result.returncode == 0, (
        f"Helper exited non-zero.\nstdout={result.stdout}\nstderr={result.stderr}"
    )

    pid_file = broker_env["pid_file"]
    tmp_file = broker_env["pid_file"].parent / (pid_file.name + ".tmp")

    # .tmp must be gone
    assert not tmp_file.exists(), (
        f"Stale .tmp file found after atomic write: {tmp_file}"
    )

    # braidd.pid must be a regular file (not a symlink, not a directory)
    assert pid_file.exists(), "braidd.pid does not exist"
    assert pid_file.is_file(), "braidd.pid is not a regular file"
    assert not pid_file.is_symlink(), "braidd.pid is a symlink (must be a real file)"

    # Cleanup
    raw = pid_file.read_text().strip()
    if raw.isdigit():
        try:
            os.kill(int(raw), 15)
        except (ProcessLookupError, PermissionError):
            pass


def test_stale_pid_cleanup_preserved(broker_env):
    """The stale-pid cleanup path (lines 37-46 of _claudex_start_broker)
    must wipe a pre-existing dead-PID file BEFORE the new write.

    Seed braidd.pid with a dead PID (99999999) and no live socket,
    invoke the helper with a working fake-node, then assert:
    1. The stale file was removed (not left behind).
    2. The new file contains the fresh broker PID.
    """
    _write_fake_node(broker_env["fake_bin"], binds_socket=True)

    # Seed a stale pid file with a known-dead PID
    dead_pid = "99999999"
    broker_env["pid_file"].write_text(f"{dead_pid}\n")
    assert broker_env["pid_file"].exists(), "pre-condition: pid file should exist"

    result = _invoke_start_broker(broker_env)
    assert result.returncode == 0, (
        f"Helper failed.\nstdout={result.stdout}\nstderr={result.stderr}"
    )

    pid_file = broker_env["pid_file"]
    assert pid_file.exists(), "braidd.pid should exist after successful broker start"

    new_pid = pid_file.read_text().strip()
    assert new_pid != dead_pid, (
        f"braidd.pid still contains the stale PID {dead_pid!r}; cleanup failed"
    )
    assert new_pid.isdigit(), f"braidd.pid content is not a PID: {new_pid!r}"

    # Cleanup
    try:
        os.kill(int(new_pid), 15)
    except (ProcessLookupError, PermissionError):
        pass
