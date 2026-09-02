---
name: do-plan
description: Execute the loaded plan via superpowers:subagent-driven-development with automatic pause at a context-size threshold. Optional argument is the STOP threshold in tokens; the default comes from runtime.do_plan_default_stop_tokens in config.yaml (default 250000). Examples — /claude-mesh:do-plan, /claude-mesh:do-plan 300k, /claude-mesh:do-plan 400000.
---

# Do Plan

Run the currently loaded implementation plan via `superpowers:subagent-driven-development` until either:

- All tasks are complete, **OR**
- Session context size crosses the configured STOP threshold (default = `runtime.do_plan_default_stop_tokens` from config.yaml, 250 000 if unset).

When the threshold is crossed, the `PostToolUse` hook `check-context-size.sh` injects a `STOP` reminder into the model context. The controller (you) must then drive the current task to a clean checkpoint via `/claude-mesh:pause-after-current-task` and yield to the user. The user will manually invoke `/claude-mesh:continue-plan-fresh-session`, start a fresh Claude session, and run `/claude-mesh:do-plan` again to resume.

## Step 1 — Determine threshold

### Resolve the config-driven default

When `$ARGUMENTS` is empty, the STOP threshold comes from `runtime.do_plan_default_stop_tokens` in config.yaml (tunable per Task 7). Resolve it via the shared loader, located through the placeholder the harness substitutes into this command's text (empty as a shell variable, hence the version-sorted glob as fallback):

```bash
# Task 2.5: CLAUDE_PLUGIN_ROOT is empty as a shell VARIABLE, but the harness substitutes the
# placeholder into this command's text before the call — it names the active copy (spelled
# without braces here, or this comment would be substituted too). Fallback glob is
# VERSION-sorted: `head -1` is directory order and can pick a stale cached version.
LOADER="${CLAUDE_PLUGIN_ROOT}/skills/shared/config-loader.sh"
[ -f "$LOADER" ] || [ -z "${GROK_SESSION_ID:-}" ] || LOADER="$(find "$HOME"/.grok/installed-plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
[ -f "$LOADER" ] || LOADER="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
[ -f "$LOADER" ] || LOADER="$(find "$HOME"/.grok/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
[ -f "$LOADER" ] || { echo "/claude-mesh:do-plan: config-loader.sh not found (is claude-mesh installed?)" >&2; exit 1; }
LOADER_ERR=$(mktemp -t do-plan-loader-XXXXXX.err) \
    || { echo "/claude-mesh:do-plan: mktemp failed" >&2; exit 1; }
trap 'rm -f "$LOADER_ERR"' EXIT

DEFAULT_STOP=$("$LOADER" get-flag do_plan_default_stop_tokens 2>"$LOADER_ERR")
case "$?" in
    0) ;;                          # configured value (already validated by validate_runtime)
    2) DEFAULT_STOP=250000 ;;      # config.yaml not found (fresh install) — sensible default
    *) cat "$LOADER_ERR" >&2; exit 1 ;;  # any other loader failure — fast-fail per §10
esac

# Dispatch model for subagents. Empty = inherit the session model.
# rc=2 (no config.yaml on a fresh install) also means inherit.
DISPATCH_MODEL=$("$LOADER" get-flag dispatch_model 2>"$LOADER_ERR")
case "$?" in
    0) ;;                      # configured value (may be empty = inherit), already validated
    2) DISPATCH_MODEL="" ;;    # config.yaml not found — inherit session model
    *) cat "$LOADER_ERR" >&2; exit 1 ;;  # any other loader failure — fast-fail
esac
echo "DISPATCH_MODEL=$DISPATCH_MODEL"   # surface to the controller (empty = inherit session)
```

The `2)` arm tolerates exactly one case — config.yaml missing on a fresh install (the distinct rc=2 from `load_or_die`). Any other failure (yaml malformed, env binary missing, validator die for an out-of-range / non-integer `do_plan_default_stop_tokens`) propagates the loader's stderr and exits. Do NOT regress this to `|| echo 250000`: swallowing all loader errors masks real config problems and contradicts the fast-fail contract.

### Parse the argument

`$ARGUMENTS` (if any) is the STOP threshold in tokens. Accepted formats:

| Input | Resolved tokens |
|---|---|
| (empty) | value of `$DEFAULT_STOP` (`runtime.do_plan_default_stop_tokens`, default `250000`) |
| `250000` | `250000` |
| `250k` / `250K` | `250000` |
| `300k`, `400k`, … | as above |

Reject anything else with a one-line error and stop. Do not guess.

### Validate threshold >= 150 000

The hook (`check-context-size.sh`) emits **nothing** below 150 000 tokens — that is a firm agreement, not a tunable. Therefore a STOP threshold below 150 000 would never fire and is rejected.

After resolving the input to an integer, check `threshold >= 150000`. If not, output exactly one line and stop:

```
/claude-mesh:do-plan: threshold must be >= 150000 tokens (the hook does not emit below 150k). Pick a value at or above 150000.
```

This floor applies to both an explicit `$ARGUMENTS` value and the config-driven `$DEFAULT_STOP`. The config side is already enforced earlier by `validate_runtime` (Task 7), so by the time `/claude-mesh:do-plan` reads `$DEFAULT_STOP` it is known to satisfy the floor — this check primarily guards an explicit too-low argument.

Do not invoke any skill, do not write the config file, do not start execution.

## Step 2 — Write per-session config file

The hook reads `<plugin-data>/state/do-plan-config-<cwd-encoded>-<session>.json` to know the STOP threshold, where `<plugin-data>` is the plugin's data dir (resolved by the loader), `<cwd-encoded>` is the absolute `pwd` with every `/` replaced by `-`, and `<session>` is the current session id. The hook (`check-context-size.sh`) computes `<cwd-encoded>` from the same `pwd` encoding and derives `<session>` from its transcript filename stem, but it takes the data dir from `$CLAUDE_PLUGIN_DATA` (set in hook contexts, `check-context-size.sh:72`) instead of asking the loader. On a marketplace install both sides land on the same absolute path; under a `--plugin-dir` dev load they do NOT — the hook gets that load's own data dir while the loader picks the one holding `config.yaml`, so this config file is written where the hook never looks and the STOP threshold silently never fires. Known divergence, fixed separately: the hook runs on every `PostToolUse`, so adding a filesystem probe there needs a cost check. Per-session keying lets two concurrent `/do-plan` runs in one cwd coexist without clobbering each other's threshold.

Use Bash. `CLAUDE_PLUGIN_DATA` is empty as a shell variable in slash-command Bash calls (CC 2.1.156), so self-discover the data dir via the loader:

```bash
# Task 2.5: CLAUDE_PLUGIN_DATA is empty as a shell variable — ask the loader for the data dir.
LOADER="${CLAUDE_PLUGIN_ROOT}/skills/shared/config-loader.sh"
[ -f "$LOADER" ] || [ -z "${GROK_SESSION_ID:-}" ] || LOADER="$(find "$HOME"/.grok/installed-plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
[ -f "$LOADER" ] || LOADER="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
[ -f "$LOADER" ] || LOADER="$(find "$HOME"/.grok/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
[ -f "$LOADER" ] || { echo "/claude-mesh:do-plan: config-loader.sh not found (is claude-mesh installed?)" >&2; exit 1; }
PLUGIN_DATA="$("$LOADER" data-dir)"
[ -n "$PLUGIN_DATA" ] || { echo "/claude-mesh:do-plan: could not resolve plugin data dir" >&2; exit 1; }
mkdir -p "$PLUGIN_DATA/state"
CWD_ENC=$(pwd | sed 's|/|-|g')

# Bind the hook to THIS session via a PER-SESSION config file
# do-plan-config-<cwd>-<session>.json. check-context-size.sh reads the file named
# for its own session (SESSION_KEY="$(basename "$TRANSCRIPT_PATH" .jsonl)"), so the
# id below must be byte-equal to that stem. Per-session keying means two concurrent
# /do-plan runs in one cwd never clobber each other.
#
# No transcript-dir glob fallback (iter-1 review ISSUE-1/2): ~/.claude/projects/
# dir names encode '.'/'_'->'-' too (not just '/'), so a sed 's|/|-|g' glob misses
# on many real paths; and `ls -t | head -1` can pick another session's transcript
# under concurrency. No glob can identify "this" session, so fail loudly instead.
# Task 4 verifies CLAUDE_CODE_SESSION_ID is populated in slash-command Bash.
SID="${CLAUDE_CODE_SESSION_ID:-}"
[ -n "$SID" ] || { echo "/claude-mesh:do-plan: CLAUDE_CODE_SESSION_ID is empty — cannot bind the context hook to this session. Aborting (see Task 4)." >&2; exit 1; }

# Atomic write with jq (not printf): robust to a concurrent hook read seeing a
# half-written file. Session is in the filename, so the body is just the threshold.
CONFIG_PATH="$PLUGIN_DATA/state/do-plan-config-${CWD_ENC}-${SID}.json"
CONFIG_TMP="$(mktemp "$PLUGIN_DATA/state/.do-plan-config-${CWD_ENC}-${SID}.XXXXXX")" \
    || { echo "/claude-mesh:do-plan: mktemp failed for config" >&2; exit 1; }
jq -nc --argjson thr <THRESHOLD> '{stop_threshold:$thr}' > "$CONFIG_TMP" \
    && mv -f "$CONFIG_TMP" "$CONFIG_PATH"
```

Substitute `<THRESHOLD>` with the integer resolved in Step 1.

The per-session filename (`do-plan-config-<cwd>-<session>.json`) binds the hook to
this session: the hook reads the file named for its own session, so an ordinary
session in the same cwd (or a stale file from a past `/do-plan`) is never seen and
gets no milestone/STOP reminders. Two concurrent `/do-plan` runs in one cwd each
own their own file and don't clobber each other. On
`/claude-mesh:continue-plan-fresh-session`, the new session re-runs `/do-plan`,
which writes a file for the new session id.

## Step 3 — Confirm in one short line

Output a single status line so the user knows the threshold took effect, e.g.:

```
/claude-mesh:do-plan: STOP threshold = 250000 tokens. Dispatch model = <DISPATCH_MODEL>, full review rigor. Starting subagent-driven-development.
```

Substitute the resolved model: print `Dispatch model = <DISPATCH_MODEL>` when it is non-empty, or `Dispatch model = session-inherited` when `DISPATCH_MODEL` is empty.

No long preamble.

## Step 4 — Invoke the executor

Use the `Skill` tool with `skill = "superpowers:subagent-driven-development"`. That skill drives the per-task loop.

## Step 5 — Execution rules (overrides on top of the skill)

These apply throughout execution and override any cost-cutting guidance the skill might imply:

### Model: dispatch tier

- The dispatch model is `$DISPATCH_MODEL`, resolved in Step 1 from config `runtime.dispatch_model`.
  - **Non-empty** → every `Agent` dispatch (implementer, spec reviewer, code quality reviewer, parallel work, any subagent) **must explicitly set `model: "<DISPATCH_MODEL>"`**.
  - **Empty** (no config value, or no config.yaml) → **omit `model:`** so each subagent **inherits this session's model**. Never explicitly pass a model *cheaper* than the session to economize on a "simple" subtask.
- The same dispatch-model rule applies to external reviewers (`superpowers:requesting-code-review` and friends) where a model parameter is accepted — set `model: "<DISPATCH_MODEL>"` when non-empty, otherwise omit it.
- If a subagent type does not accept a model override, accept the default — but do not deliberately route work to cheaper agents.

### Do not economize tokens

- Read source files in full when relevant to the task. Do not pre-truncate via `offset` / `limit` to "save context" unless the file is genuinely huge (multi-MB).
- Do not shorten or summarize subagent prompts to save input tokens. Pass full context.
- Do not skip optional verification commands to save time.

### Reviews are mandatory

- Per `superpowers:subagent-driven-development`, every task includes a **spec compliance review** and a **code quality review**. Never skip either, never short-circuit the re-review loop after a fix.
- This holds even if the task looks trivial.

## Step 6 — React to hook signals

The `PostToolUse` hook will inject system reminders of two kinds. These appear
**only** in the session where you started `/do-plan` (the hook is gated on the
per-session config file written in Step 2) — and for the rest of that session, even
after `/do-plan` finishes; in any other session (including an ordinary one in the
same cwd) it stays silent.

### Milestone (informational)

```
ctx:150k
ctx:175k
ctx:200k
ctx:225k
…
```

Every 25k starting at 150k. **Do not change behavior.** Keep executing the plan. Do not even acknowledge the milestone in chat unless it carries STOP — these are passive situational awareness markers.

### STOP signal (action required)

```
ctx:<N>k STOP threshold=<T>k - invoke /claude-mesh:pause-after-current-task
```

When you see this:

1. **Do not abort mid-task.** The current task must reach a clean checkpoint first.
2. Invoke the `pause-after-current-task` skill via the `Skill` tool. That skill encodes the entire state machine (implementer DONE → spec review ✅ → code review ✅ → mark complete in TodoWrite → checkpoint report).
3. Do **not** dispatch the next task.
4. Do **not** invoke `/claude-mesh:continue-plan-fresh-session` yourself — that is the user's manual action after they return.
5. After `pause-after-current-task` emits its standard checkpoint report, yield to the user.

The STOP signal fires exactly once per session. If it has already fired and you somehow missed it, check that the hook's STOP-marker file (`<plugin-data>/state/context-stop-<session>.txt`) exists — but in normal flow, just trust the first reminder.

## Step 7 — End of plan

If the plan reaches completion before STOP fires, follow `superpowers:subagent-driven-development` normally — final full-implementation review, `superpowers:finishing-a-development-branch`, and so on — with two additions below.

Offer the code review BEFORE `superpowers:finishing-a-development-branch`, and if the user
takes it, hold finishing entirely — no push, no PR, and no local merge either (finishing
deletes the branch after merging, and review fixes need somewhere to land) — until that
external review has run and its findings are applied. The order is the point: a
merged-and-deleted branch cannot absorb what the review finds.

`/claude-mesh:code-review-fresh-session` generates the prompt, carrying the git range and what
only this session knows — deviations from the plan, what was left unfinished, known weak spots.

Whether this session can finish the branch is a fact to check, not to guess: run
`GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -oBatchMode=yes' timeout 8 git ls-remote --exit-code origin HEAD`
(or reuse a preflight verdict already printed in this session). Both guards earn their place:
without `BatchMode` a passphrase-protected key stops at a prompt and burns the whole budget
into a false "no network", and if `command -v timeout` finds nothing — stock macOS, where it is
not installed — the line exits 127, which is indistinguishable from a silent remote. Check for
`timeout` first and, when it is absent, say the reachability is unknown rather than reporting a
verdict; `skills/shared/preflight-env.sh` has a dedicated branch for exactly this, and calls
such a verdict "invented out of a missing binary". If the remote does not answer, say plainly that
`superpowers:finishing-a-development-branch` cannot finish the job here: push and PR creation
need a network that is not available. Leave the branch for the user to finish outside. Do not
attempt the push to find out.

## Argument examples

- `/claude-mesh:do-plan` — threshold = `runtime.do_plan_default_stop_tokens` from config.yaml (default 250 000)
- `/claude-mesh:do-plan 300k` — threshold 300 000 (one-shot override; written to per-session state)
- `/claude-mesh:do-plan 400000` — threshold 400 000 (override)
- `/claude-mesh:do-plan 1m` — **reject**, format unsupported (be strict)

## Bottom line

`/claude-mesh:do-plan` = "run the plan with full rigor; pause cleanly at the configured context threshold; let me come back later, run `/claude-mesh:continue-plan-fresh-session`, and resume". The user walks away, you grind through tasks autonomously, you stop at a clean checkpoint when context fills up.
