#!/usr/bin/env bash
# check-context-size.sh — Claude Code PostToolUse hook
#
# Reads exact context usage from session transcript (usage.input_tokens +
# usage.cache_creation_input_tokens + usage.cache_read_input_tokens) and
# emits a compact additionalContext system reminder to the model.
#
# SESSION-SCOPED: active only for the session in which /do-plan was started (and
# for the rest of that session, even after /do-plan finishes). /do-plan writes a
# per-session config do-plan-config-<cwd>-<session>.json; the hook emits only if
# the file named for ITS session exists. Any other session — including an ordinary
# one in the same cwd after a past /do-plan — gets no model-visible output (the
# hook still runs its cheap mkdir preamble, then exits at the gate).
#
#   - At every INTERVAL_K mark (default 25k) starting from START_K (default 150k):
#       "ctx:175k"
#
#   - When session context first crosses the per-session STOP threshold
#     (written by the /do-plan slash command into
#      ${CLAUDE_PLUGIN_DATA}/state/do-plan-config-<cwd-encoded>-<session>.json):
#       "ctx:255k STOP threshold=250k - invoke /claude-mesh:pause-after-current-task"
#
# Silent at every other invocation (no context pollution).
#
# Source of truth: github.com/zinin/claude-mesh/hooks/check-context-size.sh
# Wired in:        github.com/zinin/claude-mesh/hooks/hooks.json
# Reads state from: ${CLAUDE_PLUGIN_DATA}/state/  (= ~/.claude/plugins/data/claude-mesh-zinin/state/)

set -euo pipefail

# ---- Input from Claude Code (JSON on stdin) ----
INPUT="$(cat || true)"
TRANSCRIPT_PATH="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
HOOK_EVENT="$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null || true)"
AGENT_ID="$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null || true)"

[ -z "$TRANSCRIPT_PATH" ] && exit 0
[ ! -f "$TRANSCRIPT_PATH" ] && exit 0

# Skip any fire where agent_id is non-empty. Covers two cases:
#
# 1. PostToolUse from inside a subagent's own tool calls — additionalContext
#    would route to the subagent's context, not the parent's.
#
# 2. SubagentStop (carries the stopping subagent's agent_id). Empirically
#    verified (see claude-tools/check-context-bug-2026-05-24-followup.md):
#    Claude Code's harness consumes the hook stdout but does NOT deliver
#    additionalContext from SubagentStop to the parent transcript. Worse,
#    if we let the script proceed, it writes STOP_FIRED=1 silently — the
#    next parent PostToolUse then sees STOP already fired and emits nothing,
#    causing the STOP signal to be lost entirely. The next parent
#    PostToolUse:Agent (fired ~62ms after SubagentStop, in parent context
#    with empty agent_id) reliably delivers the reminder. SubagentStop is
#    also no longer registered in settings.json; this guard is defense in
#    depth in case it gets re-added by mistake.
if [ -n "$AGENT_ID" ]; then
    exit 0
fi

# ---- Tunables ----
START_K="${CC_CONTEXT_START_K:-150}"        # first milestone (in thousands)
INTERVAL_K="${CC_CONTEXT_INTERVAL_K:-25}"   # milestone spacing (in thousands)

# ---- Encode cwd + resolve state dir ----
if [ -n "$CWD" ]; then
    CWD_ENC="$(printf '%s' "$CWD" | sed 's|/|-|g')"
else
    CWD_ENC="unknown"
fi

STATE_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/claude-mesh-zinin}/state"
mkdir -p "$STATE_DIR"

# ---- Per-session state (keyed off transcript filename, NOT cwd) ----
SESSION_KEY="$(basename "$TRANSCRIPT_PATH" .jsonl)"

# ---- Gate: emit ONLY inside the session where /do-plan was started ----
# /do-plan writes a PER-SESSION config do-plan-config-<cwd>-<session>.json (see
# commands/do-plan.md Step 2). No file for THIS session → /do-plan never ran here
# → exit silently (no milestone, no STOP). Keying the config by session (not just
# cwd) means two concurrent /do-plan runs in one cwd never clobber each other; old
# per-cwd configs (different filename) are simply ignored. "Silent" = no
# additionalContext; the mkdir preamble above still runs.
CONFIG_FILE="$STATE_DIR/do-plan-config-${CWD_ENC}-${SESSION_KEY}.json"
[ -f "$CONFIG_FILE" ] || exit 0

# stop_threshold from THIS session's config. Default 999_999_999 = no STOP
# (defense in depth; /do-plan always writes it). The `|| echo` keeps the hook
# alive under `set -euo pipefail` if the file is somehow malformed.
STOP_THRESHOLD="$(jq -r '.stop_threshold // 999999999' "$CONFIG_FILE" 2>/dev/null || echo "999999999")"

STATE_MILESTONE="$STATE_DIR/context-milestone-${SESSION_KEY}.txt"
STATE_STOP="$STATE_DIR/context-stop-${SESSION_KEY}.txt"

LAST_MILESTONE="$(cat "$STATE_MILESTONE" 2>/dev/null || echo "0")"
STOP_FIRED="$(cat "$STATE_STOP" 2>/dev/null || echo "0")"

# ---- Find latest assistant.usage from transcript ----
# Fast path: scan last 200 lines (transcript is JSONL, one record per line)
LATEST_USAGE="$(tail -n 200 "$TRANSCRIPT_PATH" 2>/dev/null \
    | jq -c 'select(.type=="assistant" and .message.usage!=null) | .message.usage' 2>/dev/null \
    | tail -n 1 || true)"

# Fallback: full-file scan (handles long stretches with no assistant turns)
if [ -z "$LATEST_USAGE" ]; then
    LATEST_USAGE="$(jq -c 'select(.type=="assistant" and .message.usage!=null) | .message.usage' \
        "$TRANSCRIPT_PATH" 2>/dev/null | tail -n 1 || true)"
fi

[ -z "$LATEST_USAGE" ] && exit 0

# ---- Compute context size ----
CONTEXT_SIZE="$(printf '%s' "$LATEST_USAGE" | jq -r '
    (.input_tokens // 0)
    + (.cache_creation_input_tokens // 0)
    + (.cache_read_input_tokens // 0)
' 2>/dev/null || echo "0")"

# Numeric sanity
case "$CONTEXT_SIZE" in
    ''|*[!0-9]*) exit 0 ;;
esac

CONTEXT_K=$((CONTEXT_SIZE / 1000))

# ---- Determine current milestone ----
# Floor to nearest INTERVAL_K, only if we're at/above START_K.
if [ "$CONTEXT_K" -ge "$START_K" ]; then
    CURRENT_MILESTONE=$(( (CONTEXT_K / INTERVAL_K) * INTERVAL_K ))
else
    CURRENT_MILESTONE=0
fi

# ---- Handle context shrinking (compaction): reset milestone state silently ----
if [ "$CURRENT_MILESTONE" -lt "$LAST_MILESTONE" ]; then
    echo "$CURRENT_MILESTONE" > "$STATE_MILESTONE"
    # Don't reset STOP — once fired in a session, it stays fired.
    exit 0
fi

# ---- Build message ----
MSG=""

# Milestone crossing
if [ "$CURRENT_MILESTONE" -gt "$LAST_MILESTONE" ]; then
    MSG="ctx:${CURRENT_MILESTONE}k"
    echo "$CURRENT_MILESTONE" > "$STATE_MILESTONE"
fi

# STOP signal — fires at most once per session.
# Gated by START_K floor: per agreement, the hook emits NOTHING below 150k,
# including STOP. /do-plan validates threshold >= START_K*1000 as defense in depth.
if [ "$STOP_FIRED" = "0" ] \
   && [ "$CONTEXT_K" -ge "$START_K" ] \
   && [ "$CONTEXT_SIZE" -ge "$STOP_THRESHOLD" ]; then
    STOP_K=$((STOP_THRESHOLD / 1000))
    if [ -n "$MSG" ]; then
        MSG="${MSG} STOP threshold=${STOP_K}k - invoke /claude-mesh:pause-after-current-task"
    else
        MSG="ctx:${CONTEXT_K}k STOP threshold=${STOP_K}k - invoke /claude-mesh:pause-after-current-task"
    fi
    echo "1" > "$STATE_STOP"
fi

# Silent if nothing to report
[ -z "$MSG" ] && exit 0

# ---- Emit additionalContext for the model ----
# Echo back the event we were invoked for (PostToolUse or SubagentStop) so the
# harness matches the output to the right schema.
jq -nc --arg msg "$MSG" --arg event "${HOOK_EVENT:-PostToolUse}" '{
    hookSpecificOutput: {
        hookEventName: $event,
        additionalContext: $msg
    }
}'
