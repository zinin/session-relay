#!/usr/bin/env bash
# Tests for check-context-size.sh — session-gated milestone/STOP emission.
# Each case runs the hook against an isolated tmp state dir + a synthetic
# transcript carrying a chosen usage total. No real plugin state is touched.
#
# Gating model (per-session config, iter-1 review Variant B): /do-plan writes a
# per-session file do-plan-config-<cwd>-<session>.json; the hook emits only when
# THIS session's own file exists. Concurrent /do-plan runs in one cwd never clash.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$TESTS_DIR/../../../hooks/check-context-size.sh"

FAIL=0
PASS=0

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -q -- "$needle"; then
        PASS=$((PASS+1)); echo "  PASS: $desc"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected to contain: '$needle'; got: '$haystack')"
    fi
}

assert_silent() {
    local desc="$1" haystack="$2"
    if [ -z "$haystack" ]; then
        PASS=$((PASS+1)); echo "  PASS: $desc"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected empty stdout; got: '$haystack')"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -q -- "$needle"; then
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected NOT to contain: '$needle'; got: '$haystack')"
    else
        PASS=$((PASS+1)); echo "  PASS: $desc"
    fi
}

# run_hook <usage_total> <session> <agent_id> <config_owner|-> [stop_threshold] [raw_config]
#   Runs the hook AS <session> (transcript <session>.jsonl carrying <usage_total>).
#   If <config_owner> != "-", writes a per-session config
#   do-plan-config-<cwd>-<config_owner>.json carrying {stop_threshold:[default 250000]}.
#   The gate emits only when the hook's own session owns a config, i.e.
#   <config_owner> == <session>. If [raw_config] is non-empty, that literal string
#   is written as the config body instead of well-formed JSON (malformed-file test).
run_hook() {
    local usage="$1" session="$2" agent_id="$3" config_owner="$4" threshold="${5:-250000}" raw="${6:-}"
    local cwd="/test/proj"          # encodes to -test-proj (matches the hook's sed)
    local cwd_enc="-test-proj"
    local tmp; tmp="$(mktemp -d)"
    mkdir -p "$tmp/state"
    local transcript="$tmp/${session}.jsonl"
    jq -nc --argjson u "$usage" \
        '{type:"assistant",message:{usage:{input_tokens:$u,cache_creation_input_tokens:0,cache_read_input_tokens:0}}}' \
        > "$transcript"
    if [ "$config_owner" != "-" ]; then
        local cfg="$tmp/state/do-plan-config-${cwd_enc}-${config_owner}.json"
        if [ -n "$raw" ]; then
            printf '%s\n' "$raw" > "$cfg"
        else
            jq -nc --argjson thr "$threshold" '{stop_threshold:$thr}' > "$cfg"
        fi
    fi
    local stdin; stdin="$(jq -nc --arg t "$transcript" --arg c "$cwd" --arg a "$agent_id" \
        '{transcript_path:$t,cwd:$c,hook_event_name:"PostToolUse",agent_id:$a}')"
    local out rc
    out="$(printf '%s' "$stdin" | CLAUDE_PLUGIN_DATA="$tmp" bash "$HOOK" 2>/dev/null)"; rc=$?
    rm -rf "$tmp"
    # iter-1 ISSUE-5: surface a non-zero hook exit so assert_silent (empty-stdout)
    # cannot mistake a crash (set -e abort, no stdout) for intentional silence.
    [ "$rc" -eq 0 ] || out="${out}[hook exited rc=${rc}]"
    printf '%s' "$out"
}

# run_hook_grok <usage_total> <session> <subagent_type> <config_owner|-> [stop_threshold] [data_via]
#   Grok envelope: no transcript_path, camelCase sessionId/hookEventName, usage from
#   $GROK_HOME/sessions/<encoded-cwd>/<session>/signals.json (contextTokensUsed).
#   data_via: "claude" (default) sets CLAUDE_PLUGIN_DATA; "grok" sets only GROK_PLUGIN_DATA
#   so the hook must honour the Grok alias when the Claude one is unset.
run_hook_grok() {
    local usage="$1" session="$2" subagent_type="$3" config_owner="$4" threshold="${5:-250000}" data_via="${6:-claude}"
    local cwd="/test/proj"
    local cwd_enc="-test-proj"
    local tmp; tmp="$(mktemp -d)"
    mkdir -p "$tmp/state"
    mkdir -p "$tmp/grok/sessions/%2Ftest%2Fproj/${session}"
    jq -nc --argjson u "$usage" '{contextTokensUsed:$u}' \
        > "$tmp/grok/sessions/%2Ftest%2Fproj/${session}/signals.json"
    if [ "$config_owner" != "-" ]; then
        jq -nc --argjson thr "$threshold" '{stop_threshold:$thr}' \
            > "$tmp/state/do-plan-config-${cwd_enc}-${config_owner}.json"
    fi
    local stdin; stdin="$(jq -nc --arg c "$cwd" --arg s "$session" --arg st "$subagent_type" \
        '{sessionId:$s,cwd:$c,hookEventName:"PreToolUse",subagentType:$st}')"
    local out rc env_args
    env_args=(GROK_HOME="$tmp/grok" GROK_SESSION_ID="$session")
    if [ "$data_via" = grok ]; then
        env_args+=(GROK_PLUGIN_DATA="$tmp")
        out="$(printf '%s' "$stdin" | env -u CLAUDE_PLUGIN_DATA "${env_args[@]}" bash "$HOOK" 2>/dev/null)"; rc=$?
    else
        env_args+=(CLAUDE_PLUGIN_DATA="$tmp")
        out="$(printf '%s' "$stdin" | env "${env_args[@]}" bash "$HOOK" 2>/dev/null)"; rc=$?
    fi
    rm -rf "$tmp"
    [ "$rc" -eq 0 ] || out="${out}[hook exited rc=${rc}]"
    printf '%s' "$out"
}

echo "== check-context-size: session gate =="

# --- Gate drivers: silent unless THIS session owns a /do-plan config ---
assert_silent "no config for this session → silent at 200k" \
    "$(run_hook 200000 sessA "" "-")"
assert_silent "config owned by a DIFFERENT session → silent at 200k" \
    "$(run_hook 200000 sessA "" sessB)"

# --- Regressions: inside the /do-plan session behavior is unchanged ---
assert_contains "own config + 150k → ctx:150k" "ctx:150k" \
    "$(run_hook 150000 sessA "" sessA)"

# iter-1 ISSUE-13: lock the STOP line format (milestone floored to 250k, STOP appended).
STOP_OUT="$(run_hook 260000 sessA "" sessA 250000)"
assert_contains "own config + 260k/thr250k → milestone ctx:250k" "ctx:250k" "$STOP_OUT"
assert_contains "own config + 260k/thr250k → STOP" "STOP" "$STOP_OUT"

assert_silent "subagent (agent_id set) → silent" \
    "$(run_hook 200000 sessA "sub-123" sessA)"
assert_silent "own config + 100k (below 150k floor) → silent" \
    "$(run_hook 100000 sessA "" sessA)"

# iter-1 ISSUE-12: negative STOP — threshold is read from config (300k), not hardcoded.
# Usage 260k crosses the 250k milestone but stays below the 300k STOP threshold.
NEG_OUT="$(run_hook 260000 sessA "" sessA 300000)"
assert_contains "own config + 260k/thr300k → milestone ctx:250k" "ctx:250k" "$NEG_OUT"
assert_not_contains "own config + 260k/thr300k → no STOP (below threshold)" "STOP" "$NEG_OUT"

# iter-1 ISSUE-12: malformed own config → [ -f ] gate passes; the stop_threshold jq
# fails safe under set -e (no STOP). Milestone still emits; the hook must not crash.
MAL_OUT="$(run_hook 200000 sessA "" sessA 250000 'this is not json')"
assert_contains "malformed own config → milestone still emits (no crash)" "ctx:200k" "$MAL_OUT"
assert_not_contains "malformed own config → no STOP (threshold unreadable)" "STOP" "$MAL_OUT"

echo "== check-context-size: Grok envelope (sessionId + signals.json) =="

assert_silent "Grok: no config for this session → silent at 200k" \
    "$(run_hook_grok 200000 sessG "" "-")"
assert_silent "Grok: config owned by a DIFFERENT session → silent at 200k" \
    "$(run_hook_grok 200000 sessG "" sessOther)"

GROK_OUT="$(run_hook_grok 200000 sessG "" sessG)"
assert_contains "Grok: own config + 200k signals.json → ctx:200k" "ctx:200k" "$GROK_OUT"
assert_contains "Grok: PreToolUse envelope is echoed in hookSpecificOutput" "PreToolUse" "$GROK_OUT"

GROK_STOP="$(run_hook_grok 260000 sessG "" sessG 250000)"
assert_contains "Grok: 260k/thr250k → milestone ctx:250k" "ctx:250k" "$GROK_STOP"
assert_contains "Grok: 260k/thr250k → STOP" "STOP" "$GROK_STOP"

assert_silent "Grok: own config + 100k (below 150k floor) → silent" \
    "$(run_hook_grok 100000 sessG "" sessG)"

GROK_DATA="$(run_hook_grok 200000 sessG "" sessG 250000 grok)"
assert_contains "Grok: GROK_PLUGIN_DATA (no CLAUDE_PLUGIN_DATA) + 200k → ctx:200k" "ctx:200k" "$GROK_DATA"

assert_silent "Grok: subagentType set → silent (do not write STOP_FIRED in the child)" \
    "$(run_hook_grok 200000 sessG "general-purpose" sessG)"

echo
echo "RESULTS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
