#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from braid2 import db, kernel  # noqa: E402
from braid2.ids import make_id  # noqa: E402
from braid2.policy_surface import evaluate_spawn_request  # noqa: E402
from braid2.tmux_adapter import TmuxAdapter, TmuxError  # noqa: E402


def _ok(payload: dict) -> int:
    payload.setdefault("status", "ok")
    print(json.dumps(payload, indent=2))
    return 0


def _err(message: str, code: int = 1) -> int:
    print(json.dumps({"status": "error", "message": message}, indent=2), file=sys.stderr)
    return code


def _open_db(path: str | None):
    return db.open_db(path)


def _state_dir(path: str | None) -> Path:
    db_path = Path(path) if path else db.DEFAULT_DB_PATH
    return db_path.resolve().parent


def _read_instruction(args, state_dir: Path) -> tuple[str, str]:
    if args.instruction_file:
        instruction_path = Path(args.instruction_file).resolve()
        return instruction_path.read_text(encoding="utf8"), str(instruction_path)
    if args.text:
        instruction_id = make_id("instruction")
        instruction_dir = state_dir / "instructions"
        instruction_dir.mkdir(parents=True, exist_ok=True)
        instruction_path = instruction_dir / f"{instruction_id}.txt"
        instruction_path.write_text(args.text, encoding="utf8")
        return args.text, str(instruction_path)
    raise ValueError("dispatch issue requires --instruction-file or --text")


def _tmux_adapter() -> TmuxAdapter:
    return TmuxAdapter()


def handle_bundle_create(args) -> int:
    conn = _open_db(args.db_path)
    try:
        bundle = kernel.create_bundle(
            conn,
            bundle_type=args.bundle_type,
            status=args.status,
            parent_bundle_id=args.parent_bundle_id,
            requested_by_seat=args.requested_by_seat,
            goal_ref=args.goal_ref,
            work_item_ref=args.work_item_ref,
            autonomy_budget=args.autonomy_budget,
            notes=args.notes,
        )
        return _ok({"bundle": bundle, "db_path": str(args.db_path or db.DEFAULT_DB_PATH)})
    finally:
        conn.close()


def handle_bundle_adopt(args) -> int:
    conn = _open_db(args.db_path)
    try:
        if args.transport != "tmux":
            return _err(f"unsupported adopt transport: {args.transport}")
        result = kernel.adopt_tmux_worker(
            conn,
            bundle_id=args.bundle_id,
            harness=args.harness,
            endpoint=args.endpoint,
            role=args.role,
            cwd=args.cwd,
            label=args.label,
            adapter=_tmux_adapter(),
        )
        return _ok({"adoption": result})
    except (ValueError, TmuxError) as exc:
        return _err(str(exc))
    finally:
        conn.close()


def handle_bundle_spawn(args) -> int:
    conn = _open_db(args.db_path)
    try:
        if args.transport != "tmux":
            return _err(f"unsupported spawn transport: {args.transport}")

        policy_verdict: dict | None = None
        if getattr(args, "eval_policy", False):
            verdict = evaluate_spawn_request(
                worker_harness=args.worker_harness,
                supervisor_harness=args.supervisor_harness,
                goal_ref=args.goal_ref,
                work_item_ref=args.work_item_ref,
                requested_by_seat=args.requested_by,
                parent_bundle_id=args.parent_bundle,
                transport=args.transport,
            )
            policy_verdict = verdict.to_dict()
            # Deny spawn if the authority explicitly rejected it
            if verdict.status == "denied":
                return _err(
                    f"spawn denied by policy authority: {verdict.reason}",
                    code=2,
                )

        result = kernel.spawn_tmux_supervised_bundle(
            conn,
            parent_bundle_id=args.parent_bundle,
            requested_by_seat=args.requested_by,
            worker_harness=args.worker_harness,
            supervisor_harness=args.supervisor_harness,
            goal_ref=args.goal_ref,
            work_item_ref=args.work_item_ref,
            worker_cwd=args.worker_cwd,
            worker_command=args.worker_command,
            supervisor_cwd=args.supervisor_cwd,
            supervisor_command=args.supervisor_command,
            tmux_session=args.tmux_session,
            window_name=args.window_name,
            adapter=_tmux_adapter(),
            policy_verdict=policy_verdict,
        )
        payload: dict = {"spawn": result}
        if policy_verdict is not None:
            payload["policy_verdict"] = policy_verdict
        return _ok(payload)
    except (ValueError, TmuxError) as exc:
        return _err(str(exc))
    finally:
        conn.close()


def handle_bundle_tree(args) -> int:
    conn = _open_db(args.db_path)
    try:
        tree = kernel.bundle_tree(conn, args.bundle_id)
        return _ok({"tree": tree})
    except ValueError as exc:
        return _err(str(exc))
    finally:
        conn.close()


def handle_seat_create(args) -> int:
    conn = _open_db(args.db_path)
    try:
        seat = kernel.create_seat(
            conn,
            bundle_id=args.bundle_id,
            session_id=args.session,
            role=args.role,
            status=args.status,
            parent_seat_id=args.parent_seat_id,
            label=args.label,
        )
        return _ok({"seat": seat})
    except ValueError as exc:
        return _err(str(exc))
    finally:
        conn.close()


def handle_thread_create(args) -> int:
    conn = _open_db(args.db_path)
    try:
        thread = kernel.create_thread(
            conn,
            bundle_id=args.bundle_id,
            supervisor_seat_id=args.supervisor_seat,
            target_seat_id=args.target_seat,
            target_bundle_id=args.target_bundle,
            thread_type=args.thread_type,
            status=args.status,
            wake_policy=args.wake_policy,
            escalation_policy=args.escalation_policy,
        )
        return _ok({"thread": thread})
    except ValueError as exc:
        return _err(str(exc))
    finally:
        conn.close()


def handle_dispatch_issue(args) -> int:
    conn = _open_db(args.db_path)
    try:
        seat = kernel.get_seat(conn, args.seat)
        if seat is None:
            return _err(f"seat not found: {args.seat}")
        session = kernel.get_session(conn, seat["session_id"])
        if session is None:
            return _err(f"session not found for seat {args.seat}")
        text, instruction_ref = _read_instruction(args, _state_dir(args.db_path))
        timeout_at = kernel.now_ts() + args.timeout_seconds if args.timeout_seconds else None
        attempt = kernel.issue_dispatch_attempt(
            conn,
            seat_id=args.seat,
            issued_by_seat=args.issued_by,
            instruction_ref=instruction_ref,
            timeout_at=timeout_at,
        )
        if session["transport"] != "tmux":
            return _ok({"attempt": attempt, "sent": False})
        target = kernel.get_tmux_target_for_seat(conn, args.seat)
        _tmux_adapter().send_text(target=target, text=text, enter=not args.no_enter)
        heartbeat = kernel.record_heartbeat(
            conn,
            bundle_id=seat["bundle_id"],
            seat_id=seat["seat_id"],
            session_id=session["session_id"],
            source_type="adapter",
            source_ref=target,
            state="instruction_sent",
            details={"instruction_ref": instruction_ref, "enter": not args.no_enter},
        )
        payload = {"attempt": attempt, "sent": True, "target": target, "heartbeat": heartbeat}
        if args.claim_after_send:
            payload["attempt"] = kernel.claim_dispatch_attempt(conn, attempt["attempt_id"])
        return _ok(payload)
    except (ValueError, TmuxError) as exc:
        return _err(str(exc))
    finally:
        conn.close()


def handle_dispatch_transition(args, mode: str) -> int:
    conn = _open_db(args.db_path)
    try:
        if mode == "claim":
            attempt = kernel.claim_dispatch_attempt(conn, args.attempt)
        elif mode == "timeout":
            attempt = kernel.timeout_dispatch_attempt(conn, args.attempt)
        elif mode == "fail":
            attempt = kernel.fail_dispatch_attempt(conn, args.attempt, reason=args.reason)
        else:
            raise ValueError(f"unknown dispatch transition mode: {mode}")
        return _ok({"attempt": attempt})
    except ValueError as exc:
        return _err(str(exc))
    finally:
        conn.close()


def handle_observe_capture(args) -> int:
    conn = _open_db(args.db_path)
    try:
        result = kernel.observe_tmux_seat(
            conn,
            seat_id=args.seat,
            adapter=_tmux_adapter(),
            lines=args.lines,
        )
        return _ok({"observation": result})
    except (ValueError, TmuxError) as exc:
        return _err(str(exc))
    finally:
        conn.close()


def handle_gate_resolve(args) -> int:
    conn = _open_db(args.db_path)
    try:
        gate = kernel.resolve_interaction_gate(
            conn,
            args.gate,
            resolved_by_seat=args.resolved_by,
            resolution=args.resolution,
        )
        return _ok({"gate": gate})
    except ValueError as exc:
        return _err(str(exc))
    finally:
        conn.close()


def handle_gate_list(args) -> int:
    conn = _open_db(args.db_path)
    try:
        gates = kernel.list_gates(conn, bundle_id=args.bundle_id, seat_id=args.seat_id)
        return _ok({"gates": gates, "count": len(gates)})
    finally:
        conn.close()


def handle_controller_sweep(args) -> int:
    conn = _open_db(args.db_path)
    try:
        sweep = kernel.controller_sweep(conn, bundle_id=args.bundle_id)
        return _ok({"sweep": sweep})
    finally:
        conn.close()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="braid2")
    parser.add_argument("--db-path", default=None)
    subparsers = parser.add_subparsers(dest="namespace", required=True)

    bundle = subparsers.add_parser("bundle")
    bundle_sub = bundle.add_subparsers(dest="action", required=True)

    bundle_create = bundle_sub.add_parser("create")
    bundle_create.add_argument("--bundle-type", required=True)
    bundle_create.add_argument("--status", default="provisioning")
    bundle_create.add_argument("--parent-bundle-id")
    bundle_create.add_argument("--requested-by-seat")
    bundle_create.add_argument("--goal-ref")
    bundle_create.add_argument("--work-item-ref")
    bundle_create.add_argument("--autonomy-budget")
    bundle_create.add_argument("--notes")
    bundle_create.set_defaults(func=handle_bundle_create)

    bundle_adopt = bundle_sub.add_parser("adopt")
    bundle_adopt.add_argument("--bundle-id", required=True)
    bundle_adopt.add_argument("--harness", required=True)
    bundle_adopt.add_argument("--transport", required=True)
    bundle_adopt.add_argument("--endpoint", required=True)
    bundle_adopt.add_argument("--role", required=True)
    bundle_adopt.add_argument("--cwd")
    bundle_adopt.add_argument("--label")
    bundle_adopt.set_defaults(func=handle_bundle_adopt)

    bundle_spawn = bundle_sub.add_parser("spawn")
    bundle_spawn.add_argument("--parent-bundle")
    bundle_spawn.add_argument("--requested-by")
    bundle_spawn.add_argument("--worker-harness", required=True)
    bundle_spawn.add_argument("--supervisor-harness", required=True)
    bundle_spawn.add_argument("--transport", required=True)
    bundle_spawn.add_argument("--goal-ref")
    bundle_spawn.add_argument("--work-item-ref")
    bundle_spawn.add_argument("--worker-cwd", required=True)
    bundle_spawn.add_argument("--worker-command", required=True)
    bundle_spawn.add_argument("--supervisor-cwd")
    bundle_spawn.add_argument("--supervisor-command", required=True)
    bundle_spawn.add_argument("--tmux-session", required=True)
    bundle_spawn.add_argument("--window-name")
    bundle_spawn.add_argument(
        "--eval-policy",
        action="store_true",
        default=False,
        help=(
            "Evaluate the spawn request against the shared ClauDEX policy authority "
            "before proceeding. Embeds provenance in spawn_request.request_json. "
            "Exits with code 2 if the authority explicitly denies the request."
        ),
    )
    bundle_spawn.set_defaults(func=handle_bundle_spawn)

    bundle_tree = bundle_sub.add_parser("tree")
    bundle_tree.add_argument("--bundle-id", required=True)
    bundle_tree.set_defaults(func=handle_bundle_tree)

    seat = subparsers.add_parser("seat")
    seat_sub = seat.add_subparsers(dest="action", required=True)
    seat_create = seat_sub.add_parser("create")
    seat_create.add_argument("--bundle-id", required=True)
    seat_create.add_argument("--session", required=True)
    seat_create.add_argument("--role", required=True)
    seat_create.add_argument("--status", default="active")
    seat_create.add_argument("--parent-seat-id")
    seat_create.add_argument("--label")
    seat_create.set_defaults(func=handle_seat_create)

    thread = subparsers.add_parser("thread")
    thread_sub = thread.add_subparsers(dest="action", required=True)
    thread_create = thread_sub.add_parser("create")
    thread_create.add_argument("--bundle-id", required=True)
    thread_create.add_argument("--supervisor-seat", required=True)
    thread_create.add_argument("--target-seat")
    thread_create.add_argument("--target-bundle")
    thread_create.add_argument("--thread-type", required=True)
    thread_create.add_argument("--status", default="active")
    thread_create.add_argument("--wake-policy")
    thread_create.add_argument("--escalation-policy")
    thread_create.set_defaults(func=handle_thread_create)

    dispatch = subparsers.add_parser("dispatch")
    dispatch_sub = dispatch.add_subparsers(dest="action", required=True)
    dispatch_issue = dispatch_sub.add_parser("issue")
    dispatch_issue.add_argument("--seat", required=True)
    dispatch_issue.add_argument("--issued-by")
    dispatch_issue.add_argument("--instruction-file")
    dispatch_issue.add_argument("--text")
    dispatch_issue.add_argument("--timeout-seconds", type=int, default=0)
    dispatch_issue.add_argument("--no-enter", action="store_true")
    dispatch_issue.add_argument("--claim-after-send", action="store_true")
    dispatch_issue.set_defaults(func=handle_dispatch_issue)

    dispatch_claim = dispatch_sub.add_parser("claim")
    dispatch_claim.add_argument("--attempt", required=True)
    dispatch_claim.set_defaults(func=lambda args: handle_dispatch_transition(args, "claim"))

    dispatch_timeout = dispatch_sub.add_parser("timeout")
    dispatch_timeout.add_argument("--attempt", required=True)
    dispatch_timeout.set_defaults(func=lambda args: handle_dispatch_transition(args, "timeout"))

    dispatch_fail = dispatch_sub.add_parser("fail")
    dispatch_fail.add_argument("--attempt", required=True)
    dispatch_fail.add_argument("--reason", required=True)
    dispatch_fail.set_defaults(func=lambda args: handle_dispatch_transition(args, "fail"))

    observe = subparsers.add_parser("observe")
    observe_sub = observe.add_subparsers(dest="action", required=True)
    observe_capture = observe_sub.add_parser("capture")
    observe_capture.add_argument("--seat", required=True)
    observe_capture.add_argument("--lines", type=int, default=120)
    observe_capture.set_defaults(func=handle_observe_capture)

    gate = subparsers.add_parser("gate")
    gate_sub = gate.add_subparsers(dest="action", required=True)
    gate_list = gate_sub.add_parser("list")
    gate_list.add_argument("--bundle-id")
    gate_list.add_argument("--seat-id")
    gate_list.set_defaults(func=handle_gate_list)

    gate_resolve = gate_sub.add_parser("resolve")
    gate_resolve.add_argument("--gate", required=True)
    gate_resolve.add_argument("--resolved-by")
    gate_resolve.add_argument("--resolution", required=True)
    gate_resolve.set_defaults(func=handle_gate_resolve)

    controller = subparsers.add_parser("controller")
    controller_sub = controller.add_subparsers(dest="action", required=True)
    controller_sweep = controller_sub.add_parser("sweep")
    controller_sweep.add_argument("--bundle-id")
    controller_sweep.set_defaults(func=handle_controller_sweep)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())

