#!/usr/bin/env bash
# Parse `grok models` human output into one catalog id per line.
# Does not run grok. Callers pipe `grok models` or pass --from-file.
set -u
FILE=""
case "${1:-}" in
    --from-file)
        FILE="${2:-}"
        # An empty PATH is a caller bug, not "read stdin": the guard below is [ -n "$FILE" ],
        # so `--from-file ""` would silently fall through to the pipe and parse whatever the
        # caller happened to leave on stdin. Callers pass "$GM" from a mktemp that may have
        # failed — exactly the case this catches.
        [ -n "$FILE" ] || { echo "usage: list-host-models.sh --from-file PATH (empty PATH given)" >&2; exit 64; }
        shift 2 || { echo "usage: list-host-models.sh [--from-file PATH]" >&2; exit 64; } ;;
    -*) echo "usage: list-host-models.sh [--from-file PATH]" >&2; exit 64 ;;
esac
# Lines like `  * grok-4.6 (default)` and `  - kimi-k3`, and ONLY the ones under the
# `Available models:` header. Two reasons for the anchor, both load-bearing:
#
#   * A bullet on its own is not a model. `grok models` can exit 0 while printing bulleted
#     prose — `Error: not logged in` followed by `  - run \`grok login\`` yields the slug
#     `run` without it — and HOST_MODELS is what the interactive native page is built from
#     (commands/mesh-review.md Step 2.3, "for each chunk of 4 entries from HOST_MODELS"),
#     so a bogus slug becomes a selectable reviewer and then a rejected spawn_subagent model:.
#   * An output shape this does not recognise yields NOTHING, which is the fail-closed side:
#     an empty HOST_MODELS is exactly the input `native_degraded` is written for, and that
#     path SAYS "native не запущен; остальные работают" out loud. Inventing slugs from an
#     unrecognised format has no such indicator.
#
# The header is in the captured fixture and in live output. `Default model: grok-4.6` sits
# above it and has no bullet, so it was already excluded; the anchor now excludes it twice.
if [ -n "$FILE" ]; then
    exec <"$FILE" || exit 64
fi
sed -n '/^[[:space:]]*Available models:/,$ s/^[[:space:]]*[-*][[:space:]]\{1,\}\([A-Za-z0-9][A-Za-z0-9._-]*\).*/\1/p'
