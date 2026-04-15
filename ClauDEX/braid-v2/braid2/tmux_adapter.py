from __future__ import annotations

import subprocess


class TmuxError(RuntimeError):
    pass


_INSPECT_FORMAT = (
    "#{session_name}\t#{window_index}\t#{window_name}\t#{pane_index}\t"
    "#{pane_id}\t#{pane_dead}\t#{pane_current_command}\t#{pane_current_path}"
)
_TARGET_FORMAT = "#{session_name}:#{window_index}.#{pane_index}"


class TmuxAdapter:
    transport_name = "tmux"

    def _run(self, args: list[str], *, capture_output: bool = True) -> str:
        completed = subprocess.run(
            ["tmux", *args],
            check=False,
            text=True,
            stdout=subprocess.PIPE if capture_output else None,
            stderr=subprocess.PIPE if capture_output else None,
        )
        if completed.returncode != 0:
            stderr = (completed.stderr or "").strip()
            raise TmuxError(stderr or f"tmux {' '.join(args)} failed")
        return (completed.stdout or "").strip()

    def _session_exists(self, session_name: str) -> bool:
        completed = subprocess.run(
            ["tmux", "has-session", "-t", session_name],
            check=False,
            text=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return completed.returncode == 0

    def inspect_target(self, target: str) -> dict:
        raw = self._run(["display-message", "-p", "-t", target, _INSPECT_FORMAT])
        parts = raw.split("\t")
        if len(parts) != 8:
            raise TmuxError(f"Unexpected tmux inspect output for target {target!r}: {raw!r}")
        session_name, window_index, window_name, pane_index, pane_id, pane_dead, command, cwd = parts
        return {
            "target": f"{session_name}:{window_index}.{pane_index}",
            "session_name": session_name,
            "window_index": window_index,
            "window_name": window_name,
            "pane_index": pane_index,
            "pane_id": pane_id,
            "pane_dead": pane_dead == "1",
            "current_command": command,
            "cwd": cwd,
        }

    def adopt(self, target: str) -> dict:
        return self.inspect_target(target)

    def spawn_window(
        self,
        *,
        session_name: str,
        window_name: str | None,
        cwd: str,
        command: str,
    ) -> dict:
        if self._session_exists(session_name):
            args = ["new-window", "-d", "-P", "-F", _TARGET_FORMAT, "-t", session_name]
        else:
            args = ["new-session", "-d", "-P", "-F", _TARGET_FORMAT, "-s", session_name]
        if window_name:
            args.extend(["-n", window_name])
        if cwd:
            args.extend(["-c", cwd])
        if command:
            args.append(command)
        target = self._run(args)
        return self.inspect_target(target)

    def split_pane(
        self,
        *,
        target: str,
        cwd: str,
        command: str,
        orientation: str = "h",
    ) -> dict:
        args = ["split-window", "-d", "-P", "-F", _TARGET_FORMAT, "-t", target]
        args.append("-h" if orientation == "h" else "-v")
        if cwd:
            args.extend(["-c", cwd])
        if command:
            args.append(command)
        pane_target = self._run(args)
        return self.inspect_target(pane_target)

    def send_text(self, *, target: str, text: str, enter: bool = True) -> dict:
        self._run(["send-keys", "-t", target, "-l", text], capture_output=False)
        if enter:
            self._run(["send-keys", "-t", target, "Enter"], capture_output=False)
        return self.inspect_target(target)

    def capture(self, *, target: str, lines: int | None = None) -> dict:
        args = ["capture-pane", "-p", "-J", "-t", target]
        if lines is not None and lines > 0:
            args.extend(["-S", f"-{int(lines)}"])
        text = self._run(args)
        meta = self.inspect_target(target)
        meta["text"] = text
        return meta

    def kill_session(self, session_name: str) -> None:
        self._run(["kill-session", "-t", session_name], capture_output=False)

