#!/usr/bin/env bash
# Contract and behaviour tests for skills/do-plan/SKILL.md.
# The skill is prose the controller follows plus bash fences it runs. The greps lock the
# sentences that would silently regress; the fence runs lock what Step 1 and Step 2 do.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$TESTS_DIR/.." && pwd)"
CMD="$REPO/skills/do-plan/SKILL.md"
HOOK="$REPO/hooks/check-context-size.sh"
HOOKS="$REPO/hooks/hooks.json"

FAIL=0
PASS=0

assert_ge() {
    local desc="$1" min="$2" actual="$3"
    case "$actual" in
        ''|*[!0-9]*)
            FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected a count >= $min, got '$actual')"
            return ;;
    esac
    if [ "$actual" -ge "$min" ]; then
        PASS=$((PASS+1)); echo "  PASS: $desc ($actual >= $min)"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $desc ($actual < $min)"
    fi
}
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then PASS=$((PASS+1)); echo "  PASS: $desc"
    else FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected '$expected', got '$actual')"; fi
}
assert_contains() {
    local desc="$1" needle="$2" file="$3"
    if grep -Fq -- "$needle" "$file"; then
        PASS=$((PASS+1)); echo "  PASS: $desc"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (missing in $file: '$needle')"
    fi
}
assert_has() {
    local desc="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) PASS=$((PASS+1)); echo "  PASS: $desc" ;;
        *) FAIL=$((FAIL+1)); echo "  FAIL: $desc (no '$needle' in: $haystack)" ;;
    esac
}
# The n-th ```bash fence after the heading that starts with $1.
fence() {
    awk -v h="$1" -v want="${2:-1}" '
        index($0, h) == 1 { in_sec = 1; next }
        in_sec && /^## / { exit }
        in_sec && /^```bash$/ { n++; if (n == want) { on = 1; next } }
        on && /^```$/ { exit }
        on { print }' "$CMD"
}

echo "== /do-plan: Grok session id =="
assert_contains "SID falls back to GROK_SESSION_ID" \
    'SID="${CLAUDE_CODE_SESSION_ID:-${GROK_SESSION_ID:-}}"' "$CMD"
assert_ge "abort copy names both session id vars" "1" \
    "$(grep -c 'CLAUDE_CODE_SESSION_ID and GROK_SESSION_ID' "$CMD" || true)"

echo "== /do-plan: host catalog filter =="
assert_contains "probes the live host catalog via list-host-models.sh" 'list-host-models.sh' "$CMD"
assert_contains "membership is exact-line grep -Fxq" 'grep -Fxq' "$CMD"
assert_ge "clears DISPATCH_MODEL when the slug is not a host model" "2" \
    "$(grep -c 'DISPATCH_MODEL=""' "$CMD" || true)"
assert_ge "says inherit when the slug is missing from the host catalog" "1" \
    "$(grep -c 'наследуем модель сессии' "$CMD" || true)"

echo "== /do-plan: effort is not a spawn field =="
assert_ge "tells the controller spawn_subagent has no effort field" "1" \
    "$(grep -ci 'spawn_subagent has no' "$CMD" || true)"

echo "== /do-plan: Grok reads context from signals.json, not the hook =="
assert_contains "Step 1 echoes CONTEXT_SIGNALS path" 'CONTEXT_SIGNALS=' "$CMD"
assert_contains "Grok primary usage is contextTokensUsed" 'contextTokensUsed' "$CMD"
assert_ge "says the Grok hook is not the primary STOP channel" "1" \
    "$(grep -ci 'not the primary' "$CMD" || true)"
assert_contains "poll snippet prints CONTEXT_USED= even when the file is missing" 'echo "CONTEXT_USED="' "$CMD"
assert_contains "poll snippet WARNs when signals.json is missing" 'signals.json не найден' "$CMD"
assert_contains "missing list-host-models.sh is a distinct warning" 'list-host-models.sh не найден' "$CMD"
assert_contains "Step 1 reads the Grok context window" 'contextWindowTokens' "$CMD"
assert_contains "the window warning says STOP will not fire" 'STOP не сработает' "$CMD"

echo "== /do-plan: session-relay owns its config and state =="
assert_eq "no mesh config-loader anywhere" "0" "$(grep -c 'config-loader' "$CMD" || true)"
assert_eq "no claude-mesh name left" "0" "$(grep -c 'claude-mesh' "$CMD" || true)"
assert_contains "default threshold is 400000" 'default 400000' "$CMD"
assert_contains "state lives under XDG" 'STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/session-relay"' "$CMD"

echo "== /do-plan: Step 1 behaviour =="
STEP1="$(fence '### Resolve the config-driven default')"
assert_ge "Step 1 fence extracted" "20" "$(printf '%s\n' "$STEP1" | grep -c .)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
OUT="$(cd "$T" && env -u CLAUDECODE -u GROK_SESSION_ID CLAUDE_PLUGIN_ROOT="$REPO" bash -c "$STEP1" 2>&1)"; RC=$?
assert_eq "no Claude Code, no Grok → refuses (rc 1)" "1" "$RC"
assert_has "…with the no-signal message" "do-plan здесь не поддерживается" "$OUT"
mkdir -p "$T/xdg/session-relay"
printf 'stop_tokens: 300000\ndispatch_model: opus\n' > "$T/xdg/session-relay/config.yaml"
OUT="$(cd "$T" && env -u GROK_SESSION_ID CLAUDECODE=1 CLAUDE_PLUGIN_ROOT="$REPO" XDG_CONFIG_HOME="$T/xdg" bash -c "$STEP1" 2>&1)"; RC=$?
assert_eq "Claude Code with a config → rc 0" "0" "$RC"
assert_has "reads stop_tokens" "DEFAULT_STOP=300000" "$OUT"
assert_has "reads dispatch_model" "DISPATCH_MODEL=opus" "$OUT"
printf 'stop_tokens: 400k\n' > "$T/xdg/session-relay/config.yaml"
OUT="$(cd "$T" && env -u GROK_SESSION_ID CLAUDECODE=1 CLAUDE_PLUGIN_ROOT="$REPO" XDG_CONFIG_HOME="$T/xdg" bash -c "$STEP1" 2>&1)"; RC=$?
assert_eq "a config typo stops Step 1 (rc 1)" "1" "$RC"
assert_has "…naming file and line" "$T/xdg/session-relay/config.yaml:1" "$OUT"
rm -f "$T/xdg/session-relay/config.yaml"
OUT="$(cd "$T" && env -u GROK_SESSION_ID CLAUDECODE=1 CLAUDE_PLUGIN_ROOT="$REPO" XDG_CONFIG_HOME="$T/xdg" bash -c "$STEP1" 2>&1)"; RC=$?
assert_eq "no config file → defaults, rc 0" "0" "$RC"
assert_has "…threshold 400000" "DEFAULT_STOP=400000" "$OUT"

echo "== /do-plan: Grok window check =="
WINDOW_CHECK="$(fence '### On Grok: compare the threshold with the context window')"
assert_ge "window-check fence extracted" "8" "$(printf '%s\n' "$WINDOW_CHECK" | grep -c .)"
# Runs the fence for threshold $1 and window $2 (empty = unknown) and names the case it lands in:
# "silent"; "floor C/W" (auto-compact at C is at or below the 150000 floor); "compact C/W S=n"
# (the threshold is at or above auto-compact; n is the suggested threshold). A non-zero exit, a
# second line or stray stderr comes back as it is and fails the comparison.
window_case() {
    local out rc cw s
    out="$(bash -c "$(printf '%s\n' "$WINDOW_CHECK" | sed "s/<THRESHOLD>/$1/g; s/<CONTEXT_WINDOW>/$2/g")" 2>&1)"; rc=$?
    [ "$rc" -eq 0 ] || { echo "rc $rc: $out"; return; }
    [ -n "$out" ] || { echo "silent"; return; }
    case "$out" in *$'\n'*) echo "several lines: $out"; return ;; esac
    cw="$(printf '%s\n' "$out" | sed -n 's|.*(\([0-9]*\) из \([0-9]*\)).*|\1/\2|p')"
    s="$(printf '%s\n' "$out" | sed -n 's|.*/session-relay:do-plan \([0-9]*\).*|\1|p')"
    case "$out" in
        "ВНИМАНИЕ: "*"ни при каком допустимом пороге"*) echo "floor $cw" ;;
        "ВНИМАНИЕ: порог $1 не ниже 85% окна"*) echo "compact $cw S=$s" ;;
        *) echo "unexpected: $out" ;;
    esac
}
assert_eq "W=204800 T=400000 (DKS-Ultra): past auto-compact, suggests 163000" \
    "compact 174080/204800 S=163000" "$(window_case 400000 204800)"
assert_eq "W=500000 T=400000: below auto-compact at 425000 → silent" \
    "silent" "$(window_case 400000 500000)"
assert_eq "W=500000 T=450000: past auto-compact, suggests 400000" \
    "compact 425000/500000 S=400000" "$(window_case 450000 500000)"
assert_eq "W=170000: auto-compact at 144500 is under the 150000 floor" \
    "floor 144500/170000" "$(window_case 400000 170000)"
assert_eq "empty W (window unknown) → silent" "silent" "$(window_case 400000 '')"
# Boundaries the examples above do not reach: T equal to C, C equal to 150000, S clamped.
assert_eq "T exactly at auto-compact warns too" \
    "compact 425000/500000 S=400000" "$(window_case 425000 500000)"
assert_eq "auto-compact exactly at 150000 is the floor case" \
    "floor 150000/176471" "$(window_case 400000 176471)"
assert_eq "the suggestion never goes below 150000" \
    "compact 153000/180000 S=150000" "$(window_case 400000 180000)"

echo "== /do-plan Step 2 writes the per-session file under XDG_STATE_HOME =="
STEP2="$(fence '## Step 2' | sed 's/<THRESHOLD>/400000/')"
assert_ge "Step 2 fence extracted" "10" "$(printf '%s\n' "$STEP2" | grep -c .)"
mkdir -p "$T/proj"
( cd "$T/proj" && env -u GROK_SESSION_ID XDG_STATE_HOME="$T/st" CLAUDE_CODE_SESSION_ID=sid-42 bash -c "$STEP2" ); RC=$?
assert_eq "Step 2 ran" "0" "$RC"
CWD_ENC="$(printf '%s' "$T/proj" | sed 's|/|-|g')"
WROTE="$T/st/session-relay/do-plan-config-${CWD_ENC}-sid-42.json"
assert_eq "Step 2 wrote the per-session file under XDG_STATE_HOME" "400000" "$(jq -r '.stop_threshold' "$WROTE" 2>/dev/null)"

echo "== the hook reads the directory Step 2 wrote =="
HOOK_DIR_LINE="$(grep -E '^STATE_DIR=' "$HOOK")"
HOOK_DIR="$(XDG_STATE_HOME="$T/st" bash -c "$HOOK_DIR_LINE"$'\n''printf %s "$STATE_DIR"')"
assert_eq "the hook reads the same directory" "$T/st/session-relay" "$HOOK_DIR"
# End to end: a transcript over the threshold makes the hook say STOP for this session.
TRANSCRIPT="$T/sid-42.jsonl"
jq -nc '{type:"assistant",message:{usage:{input_tokens:410000,cache_creation_input_tokens:0,cache_read_input_tokens:0}}}' > "$TRANSCRIPT"
STDIN="$(jq -nc --arg t "$TRANSCRIPT" --arg c "$T/proj" '{transcript_path:$t,cwd:$c,hook_event_name:"PostToolUse",session_id:"sid-42"}')"
HOUT="$(printf '%s' "$STDIN" | env -u CLAUDE_PLUGIN_DATA -u GROK_PLUGIN_DATA XDG_STATE_HOME="$T/st" bash "$HOOK" 2>/dev/null)"
assert_has "the hook fires STOP from the file Step 2 wrote" "STOP threshold=400k" "$HOUT"

echo "== hooks.json: Claude Code path unchanged =="
assert_ge "still registers PostToolUse" "1" "$(grep -c '"PostToolUse"' "$HOOKS" || true)"
if grep -Fq '"PreToolUse"' "$HOOKS"; then
    FAIL=$((FAIL+1)); echo "  FAIL: hooks.json must not register PreToolUse (Claude Code uses PostToolUse; Grok STOP is signals.json)"
else
    PASS=$((PASS+1)); echo "  PASS: hooks.json has no PreToolUse"
fi

echo
echo "RESULTS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
