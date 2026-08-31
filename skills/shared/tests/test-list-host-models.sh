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
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
