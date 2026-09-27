#!/usr/bin/env python3
"""Codex-only do-plan handshake, parent hooks and durable per-run state."""
import argparse
import contextlib
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time
import uuid


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


ROOT = Path(__file__).resolve().parents[1]
adapter = module("codex_transcript", ROOT / "hooks/codex-transcript.py")
config = module("relay_config", ROOT / "skills/do-plan/read-config.py")


def state_path(sid, cwd):
    base = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state")
    digest = hashlib.sha256((cwd + "\0" + sid).encode()).hexdigest()
    return base / "session-relay/codex" / (digest + ".json")


@contextlib.contextmanager
def locked(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def save(path, state):
    fd, tmp = tempfile.mkstemp(prefix=".state-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(state, stream)
            stream.write("\n")
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def load(path):
    try:
        result = json.loads(path.read_text())
        if not isinstance(result, dict):
            raise ValueError("invalid state")
        return result
    except (OSError, ValueError) as error:
        raise ValueError(f"run state unavailable: {error}") from None


def session_id(explicit):
    values = {v for v in (explicit, os.environ.get("CODEX_SESSION_ID"),
                          os.environ.get("CODEX_THREAD_ID")) if v}
    if len(values) != 1:
        raise ValueError("Codex session ID missing or conflicting: use the exact current hook/session ID; never a newest-file lookup")
    return values.pop()


def sample(state):
    result = adapter.read_usage(state.get("transcript_path"), state["session_id"],
                                state.get("model"), state.get("turn_id"),
                                state.get("invalidated_after", 0))
    # Codex defaults to compaction below its usable window. Keep margin; an explicit
    # lower host compact limit can still win and is documented, never guessed here.
    if state["threshold"] >= result["window"] * 9 // 10:
        raise adapter.Unavailable(
            f"threshold {state['threshold']} must be below 90% of reported window {result['window']}; "
            "choose a lower threshold (>=150000) or a larger model window")
    return result


def emit(event, message):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": event, "additionalContext": message}}))


def hook(payload):
    event = payload.get("hook_event_name")
    if event not in {"PostToolUse", "PreCompact", "PostCompact"} or payload.get("agent_id"):
        return
    sid, cwd = payload.get("session_id"), payload.get("cwd")
    if not isinstance(sid, str) or not isinstance(cwd, str) or not sid or not cwd:
        return
    path = state_path(sid, cwd)
    if not path.exists():
        return
    with locked(path):
        state = load(path)
        if state.get("phase") == "finished":
            return
        # Identify a child before any writes, even if a future host omits agent_id.
        try:
            adapter.read_usage(payload.get("transcript_path"), sid, payload.get("model"), payload.get("turn_id"))
        except adapter.ChildTranscript:
            return
        except adapter.Unavailable:
            pass
        state.update({k: payload.get(k) for k in ("transcript_path", "model")})
        # 0.157.1 compact events omit turn_id despite newer schemas documenting it.
        # Only a parent PostToolUse or an explicit compact field changes this identity.
        if event == "PostToolUse" or payload.get("turn_id"):
            state["turn_id"] = payload.get("turn_id")
        state["hook_seen"] = True
        message = ""
        if event == "PostCompact":
            state["invalidated_after"] = time.time()
        try:
            usage = sample(state)
            state["error"] = ""
            if state["phase"] == "probing" and event == "PostToolUse":
                state["phase"] = "ready"
                message = (f"session-relay Codex ready run_id={state['run_id']} "
                           f"session_id={sid} used={usage['used']} window={usage['window']}. "
                           "This is the parent hook receipt; arm only this run.")
            elif state["phase"] == "active" and not state.get("stop_fired"):
                if usage["used"] >= state["threshold"]:
                    state["stop_fired"] = True
                    state["crossed_at_usage"] = usage["used"]
        except adapter.Unavailable as error:
            reason = str(error)
            if (event == "PostToolUse" and state["phase"] == "active"
                    and not state.get("stop_fired") and state.get("error") != reason):
                message = (f"session-relay Codex telemetry unavailable: {reason}. "
                           "Finish the current task; check telemetry before any new dispatch. "
                           "If still unavailable, invoke pause-after-current-task.")
            state["error"] = reason
        if event == "PreCompact":
            state["invalidated_after"] = time.time()
        # Compact hooks support only common output, not additionalContext. Latch
        # crossing there, but consume the one-time delivery only on a parent tool.
        if event == "PostToolUse" and state.get("stop_fired") and not state.get("stop_delivered"):
            state["stop_delivered"] = True
            message = (f"ctx:{state['crossed_at_usage']} STOP threshold={state['threshold']} "
                       "- invoke /session-relay:pause-after-current-task; finish reviews "
                       "and persist progress, then do not dispatch the next task.")
        save(path, state)
        if message:
            emit(event, message)


def main():
    if sys.argv[1:] == ["hook"]:
        try:
            payload = json.load(sys.stdin)
            if isinstance(payload, dict):
                hook(payload)
        except (ValueError, OSError) as error:
            print(f"session-relay Codex hook: {error}", file=sys.stderr)
            return 1
        return 0
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["probe", "arm", "check", "finish"])
    parser.add_argument("value", nargs="?", default="")
    parser.add_argument("--session-id", help="exact current session ID when the host provides no shell ID")
    args = parser.parse_args()
    try:
        sid = session_id(args.session_id)
        cwd = os.getcwd()
        path = state_path(sid, cwd)
        with locked(path):
            if args.command == "probe":
                values = config.parse(config.default_path())  # validate even with an override
                raw = args.value or values["stop_tokens"]
                if not re.fullmatch(r"[0-9]+[kK]?", raw):
                    raise ValueError("threshold must be an integer or use k (e.g. 300k)")
                threshold = int(raw[:-1]) * 1000 if raw[-1:] in ("k", "K") else int(raw)
                if threshold < 150000:
                    raise ValueError("threshold must be >= 150000 tokens")
                state = dict(session_id=sid, cwd=cwd, run_id=uuid.uuid4().hex,
                             threshold=threshold, phase="probing", stop_fired=False,
                             error="hook receipt missing; check installation and trust via /hooks",
                             dispatch_model="session-inherited")
                save(path, state)
                if values["dispatch_model"]:
                    print(f"Codex: dispatch_model={values['dispatch_model']} ignored; inherit session model and effort", file=sys.stderr)
                print(json.dumps(state))
                return 0
            state = load(path)
            if not args.value or state.get("run_id") != args.value:
                raise ValueError("run_id does not match this session's current run")
            if args.command == "finish":
                state["phase"] = "finished"
                save(path, state)
                print(json.dumps({"phase": "finished", "run_id": args.value}))
                return 0
            if state["phase"] not in {"ready", "active"}:
                raise ValueError(state.get("error") or "parent hook receipt missing; check /hooks")
            try:
                usage = sample(state)
                error = ""
            except adapter.Unavailable as problem:
                usage, error = {}, str(problem)
            # A checkpoint can see a crossing before the hook. Persist it now;
            # only PostToolUse consumes the one-time delivery marker.
            if not error and usage["used"] >= state["threshold"]:
                state["stop_fired"] = True
                state["crossed_at_usage"] = usage["used"]
                save(path, state)
            if args.command == "arm":
                if error:
                    raise ValueError(error)
                state["phase"] = "active"
                save(path, state)
            print(json.dumps(dict(usage, phase=state["phase"], run_id=state["run_id"],
                                  threshold=state["threshold"], error=error,
                                  pause_required=bool(error or state["stop_fired"] or
                                                      usage.get("used", 0) >= state["threshold"]))))
            return 0
    except (ValueError, OSError) as error:
        print(f"/session-relay:do-plan (Codex): {error}", file=sys.stderr)
        if isinstance(error, PermissionError):
            print("Grant the session-relay state directory with Codex --add-dir, or use a writable XDG_STATE_HOME for both shell and hooks.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
