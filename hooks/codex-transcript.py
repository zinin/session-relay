"""Adapter for Codex 0.157.1 rollout JSONL, NOT a stable Codex API.

Return the last completed request's context usage, never lifetime billing usage.
Unknown, stale, compacted or mismatched data is unavailable, not zero.
"""
import datetime
import json
from pathlib import Path
import time


class Unavailable(ValueError):
    pass


class ChildTranscript(Unavailable):
    pass


def integer(value):
    return type(value) is int and value >= 0


def timestamp(value):
    try:
        parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError()
        return parsed.timestamp()
    except (ValueError, AttributeError, TypeError):
        raise Unavailable("usage timestamp is missing or unrecognized") from None


def read_usage(path, session_id, model, turn_id, invalidated_after=0):
    if not path:
        raise Unavailable("no transcript_path (ephemeral/remote mode is unsupported)")
    try:
        with Path(path).open(encoding="utf-8") as stream:
            rows = []
            for line in stream:
                if not line.endswith("\n"):
                    break  # rollout writer may be midway through its final record
                try:
                    row = json.loads(line)
                except ValueError:
                    raise Unavailable("unrecognized transcript JSONL") from None
                if not isinstance(row, dict):
                    raise Unavailable("unrecognized transcript record")
                rows.append(row)
    except (OSError, UnicodeError) as error:
        raise Unavailable(f"transcript unavailable: {error}") from None
    if not rows or rows[0].get("type") != "session_meta":
        raise Unavailable("transcript has no session_meta identity")
    meta = rows[0].get("payload", {})
    if not isinstance(meta, dict):
        raise Unavailable("unrecognized transcript metadata")
    if isinstance(meta.get("source"), dict) and "subagent" in meta["source"]:
        raise ChildTranscript("subagent transcript")
    if meta.get("id") != session_id:
        raise Unavailable("transcript session_id mismatch")
    if meta.get("cli_version") != "0.157.1":
        raise Unavailable("unverified Codex transcript version (tested: 0.157.1)")

    current_model = current_turn = None
    sample = None
    previous_measurement = None
    for row in rows[1:]:
        payload = row.get("payload")
        if not isinstance(payload, dict):
            continue
        if row.get("type") == "turn_context":
            next_model, next_turn = payload.get("model"), payload.get("turn_id")
            if (next_model, next_turn) != (current_model, current_turn):
                sample = None
            current_model, current_turn = next_model, next_turn
        elif row.get("type") == "compacted" or (
            row.get("type") == "event_msg" and payload.get("type") == "context_compacted"
        ):
            sample = None
        elif row.get("type") == "event_msg" and payload.get("type") == "token_count":
            info = payload.get("info")
            if info is None:  # rate-limit-only event, not a usage update
                continue
            if not isinstance(info, dict):
                raise Unavailable("unrecognized token_count info")
            # Rate-limit updates can re-emit FULL info. Do not refresh its age or
            # reassign it to a new model/turn. Cumulative usage identifies a new
            # measurement only; it is never used as context size.
            measurement = (info.get("total_token_usage"), info.get("last_token_usage"))
            if measurement == previous_measurement:
                continue
            previous_measurement = measurement
            sample = (row, info)
    if current_model != model or not model:
        raise Unavailable("model changed; waiting for matching model usage")
    if current_turn != turn_id or not turn_id:
        raise Unavailable("turn changed; waiting for current turn usage")
    if sample is None:
        raise Unavailable("no usage yet; waiting for a completed model request")
    row, info = sample
    if not isinstance(info, dict) or not isinstance(info.get("last_token_usage"), dict):
        raise Unavailable("unrecognized last_token_usage")
    usage = info["last_token_usage"]
    inputs, outputs, total = (usage.get(k) for k in ("input_tokens", "output_tokens", "total_tokens"))
    if not all(integer(v) for v in (inputs, outputs, total)) or inputs == 0 or total != inputs + outputs:
        raise Unavailable("usage is an estimate or unrecognized; waiting for real model usage")
    window = info.get("model_context_window")
    if not integer(window) or window == 0:
        raise Unavailable("model context window unavailable")
    measured_at = timestamp(row.get("timestamp"))
    if measured_at <= invalidated_after:
        raise Unavailable("compaction invalidated usage; waiting for a new model request")
    age = time.time() - measured_at
    if age > 300 or age < -30:
        raise Unavailable("stale usage; waiting for a fresh model request")
    return {"used": total, "window": window, "measured_at": measured_at,
            "model": model, "turn_id": turn_id}
