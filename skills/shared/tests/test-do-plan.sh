#!/usr/bin/env bash
# Contract tests for /do-plan host-aware dispatch and Grok session binding.
# The command is prose the controller follows; these greps lock the sentences
# that would silently regress to "always pass opus" or "abort without CLAUDE_CODE_SESSION_ID".
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$TESTS_DIR/../../.." && pwd)"
CMD="$REPO/commands/do-plan.md"
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

assert_contains() {
    local desc="$1" needle="$2" file="$3"
    if grep -Fq -- "$needle" "$file"; then
        PASS=$((PASS+1)); echo "  PASS: $desc"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (missing in $file: '$needle')"
    fi
}

echo "== /do-plan: Grok session id =="
assert_contains "SID falls back to GROK_SESSION_ID" \
    'SID="${CLAUDE_CODE_SESSION_ID:-${GROK_SESSION_ID:-}}"' "$CMD"
assert_ge "abort copy names both session id vars" "1" \
    "$(grep -c 'CLAUDE_CODE_SESSION_ID and GROK_SESSION_ID' "$CMD" || true)"

echo "== /do-plan: host catalog filter =="
assert_contains "probes the live host catalog via list-host-models.sh" \
    'list-host-models.sh' "$CMD"
assert_contains "membership is exact-line grep -Fxq" \
    'grep -Fxq' "$CMD"
assert_ge "clears DISPATCH_MODEL when the slug is not a host model (rc=2 inherit plus host-miss)" "2" \
    "$(grep -c 'DISPATCH_MODEL=""' "$CMD" || true)"
assert_ge "says inherit when the slug is missing from the host catalog" "1" \
    "$(grep -c 'наследуем модель сессии' "$CMD" || true)"

echo "== /do-plan: effort is not a spawn field =="
assert_ge "tells the controller spawn_subagent has no effort field" "1" \
    "$(grep -ci 'spawn_subagent has no' "$CMD" || true)"

echo "== /do-plan: Grok reads context from signals.json, not the hook =="
assert_contains "Step 1 echoes CONTEXT_SIGNALS path" \
    'CONTEXT_SIGNALS=' "$CMD"
assert_contains "Grok primary usage is contextTokensUsed" \
    'contextTokensUsed' "$CMD"
assert_ge "says the Grok hook is not the primary STOP channel" "1" \
    "$(grep -ci 'not the primary' "$CMD" || true)"

echo "== hooks.json: Grok delivery path =="
assert_ge "registers PreToolUse (Grok additionalContext path)" "1" \
    "$(grep -c '"PreToolUse"' "$HOOKS" || true)"
assert_ge "sets an explicit timeout (Grok observe default is 5s)" "1" \
    "$(grep -c '"timeout"' "$HOOKS" || true)"

echo
echo "RESULTS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
