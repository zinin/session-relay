#!/usr/bin/env bash
# Parse `grok models` human output into one catalog id per line.
# Does not run grok. Callers pipe `grok models` or pass --from-file.
set -u
FILE=""
case "${1:-}" in
    --from-file) FILE="${2:-}"; shift 2 || { echo "usage: list-host-models.sh [--from-file PATH]" >&2; exit 64; } ;;
    -*) echo "usage: list-host-models.sh [--from-file PATH]" >&2; exit 64 ;;
esac
# Lines like `  * grok-4.6 (default)` and `  - kimi-k3`. Do not match
# `Default model: grok-4.6` — that line has no leading * or -.
if [ -n "$FILE" ]; then
    exec <"$FILE" || exit 64
fi
sed -n 's/^[[:space:]]*[-*][[:space:]]\{1,\}\([A-Za-z0-9][A-Za-z0-9._-]*\).*/\1/p'
