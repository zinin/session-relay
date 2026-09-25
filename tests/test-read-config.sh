#!/usr/bin/env bash
# Tests for skills/do-plan/read-config.py — session-relay's two-key config.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
READ="$TESTS_DIR/../skills/do-plan/read-config.py"
FAIL=0
PASS=0
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then PASS=$((PASS+1)); echo "  PASS: $desc"
    else FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected '$expected', got '$actual')"; fi
}
assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) PASS=$((PASS+1)); echo "  PASS: $desc" ;;
        *) FAIL=$((FAIL+1)); echo "  FAIL: $desc (no '$needle' in '$haystack')" ;;
    esac
}
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
run() {   # $1 = config body or "-" for no file; rest = read-config.py args. Sets OUT ERR RC.
    local body="$1"; shift
    rm -f "$T/config.yaml"
    [ "$body" = "-" ] || printf '%s' "$body" > "$T/config.yaml"
    OUT="$(python3 "$READ" --file "$T/config.yaml" "$@" 2>"$T/err")"; RC=$?
    ERR="$(cat "$T/err")"
}

echo "=== no file: defaults ==="
run - get stop_tokens;    assert_eq "stop_tokens defaults to 400000" "400000" "$OUT"; assert_eq "rc 0" "0" "$RC"
run - get dispatch_model; assert_eq "dispatch_model defaults to empty" "" "$OUT"; assert_eq "rc 0" "0" "$RC"

echo "=== both keys, comments, blank lines, quotes ==="
CFG=$'# session-relay\n\nstop_tokens: 300000   # pause earlier\ndispatch_model: "opus"\n'
run "$CFG" get stop_tokens;    assert_eq "stop_tokens read" "300000" "$OUT"
run "$CFG" get dispatch_model; assert_eq "quotes stripped" "opus" "$OUT"
run $'dispatch_model:\n' get dispatch_model; assert_eq "an empty value means unset" "" "$OUT"; assert_eq "…rc 0" "0" "$RC"
run $'dispatch_model: us.anthropic.claude-opus-4-v2:0\n' get dispatch_model
assert_eq "provider ids with . : pass" "us.anthropic.claude-opus-4-v2:0" "$OUT"

echo "=== errors name the file and the line ==="
run $'stop_tokens: 149999\n' get stop_tokens
assert_eq "below the floor → rc 1" "1" "$RC"
assert_contains "…names the file and line" "$T/config.yaml:1" "$ERR"
assert_contains "…and the floor" "150000" "$ERR"
run $'\nstop_tokens: 400k\n' get stop_tokens
assert_eq "400k is not an integer → rc 1" "1" "$RC"
assert_contains "…names line 2" "$T/config.yaml:2" "$ERR"
run $'stop_token: 400000\n' get stop_tokens
assert_eq "a typo'd key → rc 1" "1" "$RC"
assert_contains "…says unknown key" "unknown key 'stop_token'" "$ERR"
run $'stop_tokens: 400000\nstop_tokens: 300000\n' get stop_tokens
assert_eq "a duplicate key → rc 1" "1" "$RC"
assert_contains "…says duplicate" "duplicate key 'stop_tokens'" "$ERR"
run $'just text\n' get stop_tokens
assert_eq "a line without a colon → rc 1" "1" "$RC"
run $'dispatch_model: -rf\n' get dispatch_model
assert_eq "a flag-looking model → rc 1" "1" "$RC"
run $'stop_tokens:\n' get stop_tokens
assert_eq "an empty stop_tokens → rc 1" "1" "$RC"

echo "=== default path follows XDG_CONFIG_HOME ==="
mkdir -p "$T/xdg/session-relay"
printf 'stop_tokens: 250000\n' > "$T/xdg/session-relay/config.yaml"
OUT="$(XDG_CONFIG_HOME="$T/xdg" python3 "$READ" get stop_tokens)"
assert_eq "reads \$XDG_CONFIG_HOME/session-relay/config.yaml" "250000" "$OUT"
OUT="$(env -u XDG_CONFIG_HOME HOME="$T/nohome" python3 "$READ" get stop_tokens)"
assert_eq "no XDG, no file under HOME → default" "400000" "$OUT"
OUT="$(XDG_CONFIG_HOME="$T/xdg" python3 "$READ" path)"
assert_eq "path prints the file it reads" "$T/xdg/session-relay/config.yaml" "$OUT"

echo "=== the shipped example parses ==="
EXAMPLE="$TESTS_DIR/../config.example.yaml"
OUT="$(python3 "$READ" --file "$EXAMPLE" get stop_tokens)"; assert_eq "config.example.yaml: stop_tokens" "400000" "$OUT"
OUT="$(python3 "$READ" --file "$EXAMPLE" get dispatch_model)"; assert_eq "config.example.yaml: dispatch_model left out" "" "$OUT"

echo "=== usage ==="
python3 "$READ" get nothing >/dev/null 2>&1; assert_eq "unknown key to get → rc 64" "64" "$?"
python3 "$READ" >/dev/null 2>&1; assert_eq "no command → rc 64" "64" "$?"

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
