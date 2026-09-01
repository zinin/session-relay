#!/usr/bin/env bash
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$TESTS_DIR/../list-host-models.sh"
FIXTURE="$TESTS_DIR/fixtures/grok-models-2026-08-31.txt"
FAIL=0
PASS=0
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then PASS=$((PASS+1)); echo "  PASS: $desc"
    else FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected '$expected', got '$actual')"; fi
}
# script missing → this test fails until Task 2 step 3
GOT=$("$SCRIPT" --from-file "$FIXTURE" | tr '\n' ' ')
assert_eq "first slug is grok-4.6" "grok-4.6" "$("$SCRIPT" --from-file "$FIXTURE" | head -1)"
assert_eq "count is 20" "20" "$("$SCRIPT" --from-file "$FIXTURE" | wc -l | tr -d ' ')"
assert_eq "does not emit Default model line as a slug twice extra" "1" \
    "$("$SCRIPT" --from-file "$FIXTURE" | grep -c '^grok-4.6$')"
assert_eq "last slug is codex-luna" "codex-luna" "$("$SCRIPT" --from-file "$FIXTURE" | tail -1)"
printf '' | "$SCRIPT" >/dev/null
assert_eq "empty stdin is rc 0" "0" "$?"

# Bulleted prose that is NOT the model list must yield nothing. `grok models` can exit 0 while
# printing this, and HOST_MODELS is what the interactive native page is built from, so a slug
# invented here becomes a selectable reviewer and then a rejected spawn_subagent model:.
GOT=$(printf 'Error: not logged in\n  - run `grok login`\n' | "$SCRIPT")
assert_eq "an error message yields no slugs" "" "$GOT"
GOT=$(printf 'Notes:\n  * upgrade available\n  - see docs\n' | "$SCRIPT")
assert_eq "a Notes section yields no slugs" "" "$GOT"

# Output with no recognised header yields nothing rather than guessing: an empty HOST_MODELS is
# exactly the input native_degraded is written for, and that path says so out loud.
GOT=$(printf '  - grok-4.6\n  - grok-4.5\n' | "$SCRIPT")
assert_eq "bullets without the header yield nothing" "" "$GOT"

# Everything under the header is still taken, both bullet characters, and the unbulleted
# `Default model:` line above it is excluded.
GOT=$(printf 'Default model: grok-4.6\n\nAvailable models:\n  * grok-4.6 (default)\n  - kimi-k3\n' | "$SCRIPT" | tr '\n' ' ')
assert_eq "header section takes both bullet forms, not the Default line" "grok-4.6 kimi-k3 " "$GOT"
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
