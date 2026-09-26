---
name: do-plan
description: Execute the loaded plan via superpowers:subagent-driven-development with automatic pause at a context-size threshold. Optional argument is the STOP threshold in tokens; the default comes from stop_tokens in ~/.config/session-relay/config.yaml (default 400000). Examples — /session-relay:do-plan, /session-relay:do-plan 300k, /session-relay:do-plan 400000.
---

# Do Plan

Run the currently loaded implementation plan via `superpowers:subagent-driven-development` until either:

- All tasks are complete, **OR**
- Session context size crosses the configured STOP threshold (default = `stop_tokens` from `~/.config/session-relay/config.yaml`, 400 000 if unset).

When the threshold is crossed, stop at a clean checkpoint via `/session-relay:pause-after-current-task` and yield to the user. The user will manually invoke `/session-relay:continue-plan-fresh-session`, start a fresh session, and run `/session-relay:do-plan` again to resume.

How you learn that the threshold was crossed depends on the host:

- **Claude Code:** the `PostToolUse` hook `check-context-size.sh` injects a `STOP` reminder into the model context. That is the primary signal. Follow Step 6.
- **Anywhere else** (Codex, a bare terminal): nothing reports the context size, so a run would never pause. Step 1 refuses to start there.
- **Grok:** that hook is **not the primary** STOP channel. Grok ignores `PostToolUse` stdout, and the model does not receive the status-line `/session-info` / `/context` numbers. After each task checkpoint, read `contextTokensUsed` from the session `signals.json` (path echoed as `CONTEXT_SIGNALS=` in Step 1). If it is `>=` the STOP threshold, treat that as STOP and follow Step 6. Do not wait for a hook reminder.

## Step 1 — Determine threshold

### Resolve the config-driven default

When no argument is given, the STOP threshold is `stop_tokens` from `~/.config/session-relay/config.yaml` (`$XDG_CONFIG_HOME/session-relay/config.yaml` when that is set), read by `read-config.py` next to this file. Claude Code substitutes the plugin root into this file's text; Grok and Codex do not, hence the version-sorted globs as fallback — installed-plugins first, and only inside a Grok session:

```bash
# A STOP needs a signal: the PostToolUse hook on Claude Code (CLAUDECODE is set in its Bash
# calls), signals.json on Grok (GROK_SESSION_ID). Anywhere else — Codex, for one — nothing tells
# this session how full its context is, and a run that cannot pause must not start.
if [ -z "${CLAUDECODE:-}" ] && [ -z "${GROK_SESSION_ID:-}" ]; then
    echo "/session-relay:do-plan: do-plan здесь не поддерживается: нет сигнала о заполнении контекста (нужен Claude Code или Grok)." >&2
    exit 1
fi
SR_READ="${CLAUDE_PLUGIN_ROOT}/skills/do-plan/read-config.py"
[ -f "$SR_READ" ] || [ -z "${GROK_SESSION_ID:-}" ] || SR_READ="$(find "$HOME"/.grok/installed-plugins -path '*session-relay*/skills/do-plan/read-config.py' 2>/dev/null | sort -V | tail -1)" || true
[ -f "$SR_READ" ] || SR_READ="$(find "$HOME"/.claude/plugins -path '*session-relay*/skills/do-plan/read-config.py' 2>/dev/null | sort -V | tail -1)" || true
[ -f "$SR_READ" ] || SR_READ="$(find "$HOME"/.grok/plugins -path '*session-relay*/skills/do-plan/read-config.py' 2>/dev/null | sort -V | tail -1)" || true
[ -f "$SR_READ" ] || { echo "/session-relay:do-plan: read-config.py not found (is session-relay installed?)" >&2; exit 1; }
GM=""
trap 'rm -f "$GM"' EXIT

# read-config.py prints the default for a missing file and exits 1 with <file>:<line> on a
# config mistake — a typo must never quietly move the threshold, so both reads fail fast.
DEFAULT_STOP=$(python3 "$SR_READ" get stop_tokens) || exit 1
# Dispatch model for subagents. Empty = inherit the session model.
DISPATCH_MODEL=$(python3 "$SR_READ" get dispatch_model) || exit 1
# On Grok, pass dispatch_model only if it is a live host slug. opus is not.
# Probe failure / empty catalog / missing timeout(1) → inherit (fail closed):
# better than a spawn_subagent rejected for an unknown model.
if [ -n "${GROK_SESSION_ID:-}" ] && [ -n "$DISPATCH_MODEL" ]; then
    HOST_MODELS=""
    if ! command -v timeout >/dev/null 2>&1; then
        echo "ВНИМАНИЕ: timeout(1) отсутствует — grok models не запускался; dispatch_model=$DISPATCH_MODEL не проверялся, наследуем модель сессии" >&2
        DISPATCH_MODEL=""
    else
        GM=$(mktemp -t do-plan-host-models-XXXXXX) \
            || { echo "/session-relay:do-plan: mktemp failed for host catalog" >&2; exit 1; }
        GMT="${GROK_MODELS_TIMEOUT:-${PREFLIGHT_CLI_TIMEOUT:-30}}"
        case "$GMT" in
            ''|*[!0-9]*|0) echo "ВНИМАНИЕ: GROK_MODELS_TIMEOUT='$GMT' не число — использую 30" >&2; GMT=30 ;;
        esac
        LIST_HM="$(dirname "$SR_READ")/list-host-models.sh"
        if [ ! -f "$LIST_HM" ]; then
            echo "ВНИМАНИЕ: list-host-models.sh не найден — dispatch_model=$DISPATCH_MODEL не проверялся, наследуем модель сессии" >&2
            DISPATCH_MODEL=""
        elif timeout "$GMT" grok models >"$GM" 2>/dev/null; then
            HOST_MODELS=$(bash "$LIST_HM" --from-file "$GM")
        fi
        rm -f "$GM"
        GM=""
        if [ -z "$DISPATCH_MODEL" ]; then
            : # already inherit (missing list-host-models.sh)
        elif [ -z "$HOST_MODELS" ]; then
            echo "ВНИМАНИЕ: каталог хоста пуст или grok models не удался — dispatch_model=$DISPATCH_MODEL не передаём, наследуем модель сессии" >&2
            DISPATCH_MODEL=""
        elif ! printf '%s\n' "$HOST_MODELS" | grep -Fxq -- "$DISPATCH_MODEL"; then
            echo "ВНИМАНИЕ: dispatch_model=$DISPATCH_MODEL нет в каталоге хоста — наследуем модель сессии" >&2
            DISPATCH_MODEL=""
        fi
    fi
    echo "HOST_MODELS=[$(printf '%s' "$HOST_MODELS" | tr '\n' ' ')]"
fi
echo "DEFAULT_STOP=$DEFAULT_STOP"       # the threshold when no argument was given
echo "DISPATCH_MODEL=$DISPATCH_MODEL"   # surface to the controller (empty = inherit session)
# Grok: the controller polls this file for STOP (Step 6). Same glob the hook uses.
if [ -n "${GROK_SESSION_ID:-}" ]; then
    grok_home="${GROK_HOME:-$HOME/.grok}"
    CONTEXT_SIGNALS=""
    for f in "$grok_home"/sessions/*/"$GROK_SESSION_ID"/signals.json; do
        [ -f "$f" ] && CONTEXT_SIGNALS="$f" && break
    done
    echo "CONTEXT_SIGNALS=$CONTEXT_SIGNALS"
    # The window this session's model has; checked against the threshold below.
    CONTEXT_WINDOW=""
    [ -z "$CONTEXT_SIGNALS" ] || CONTEXT_WINDOW=$(jq -r '.contextWindowTokens // empty' "$CONTEXT_SIGNALS" 2>/dev/null)
    echo "CONTEXT_WINDOW=$CONTEXT_WINDOW"
fi
```

A missing config file is not an error — the defaults apply. Any mistake in an existing file (an unknown or repeated key, `stop_tokens` that is not a whole number or is below 150000, a `dispatch_model` outside `[A-Za-z0-9._:@-]`) stops here with `<file>:<line>: <reason>`. Do NOT regress this to a silent default: a typo would move the STOP threshold without anyone noticing.

On Grok, `CONTEXT_SIGNALS=` and `CONTEXT_WINDOW=` are empty on a session's first turn: Grok writes `signals.json` when a turn ends. Step 6's snippet re-globs the file at each task checkpoint; at the first one that finds it, run the window check below with its `contextWindowTokens`.

### Parse the argument

The argument is the text after the skill name in the invocation (Claude Code appends it as `ARGUMENTS:`; Grok and Codex pass it in the message). It is the STOP threshold in tokens. Accepted formats:

| Input | Resolved tokens |
|---|---|
| (empty) | the `DEFAULT_STOP=` value printed in Step 1 (`stop_tokens`, default `400000`) |
| `250000` | `250000` |
| `250k` / `250K` | `250000` |
| `300k`, `400k`, … | as above |

Reject anything else with a one-line error and stop. Do not guess.

### Validate threshold >= 150 000

The hook (`check-context-size.sh`) emits **nothing** below 150 000 tokens — that is a firm agreement, not a tunable. Therefore a STOP threshold below 150 000 would never fire and is rejected. On Grok the primary STOP channel is the `signals.json` poll, not the hook; the same floor still applies so one threshold cannot mean two different things across hosts.

After resolving the input to an integer, check `threshold >= 150000`. If not, output exactly one line and stop:

```
/session-relay:do-plan: threshold must be >= 150000 tokens (the hook does not emit below 150k). Pick a value at or above 150000.
```

This floor applies to both an explicit argument and the config-driven `DEFAULT_STOP`. `read-config.py` already enforces it for the config, so this check primarily guards an explicit too-low argument.

Do not invoke any skill, do not write the config file, do not start execution.

### On Grok: compare the threshold with the context window

Grok auto-compacts the conversation at 85% of the model's context window (its default; see Step 6), so the count never reaches a threshold at or above that point and STOP would never fire. When that 85% is itself at or below the 150000 floor, no allowed threshold can fire.

On Grok, once the threshold is resolved and has passed the 150000 check above, run this with `<THRESHOLD>` replaced by that integer and `<CONTEXT_WINDOW>` by the number Step 1 printed after `CONTEXT_WINDOW=`. When Step 1 printed nothing there (no `signals.json` yet, or no such field), the window is unknown: replace the placeholder with nothing, and the fence says nothing.

```bash
THRESHOLD=<THRESHOLD>
WINDOW=<CONTEXT_WINDOW>
# No whole number: the window is unknown, so there is nothing to compare.
case "$WINDOW" in ''|*[!0-9]*) exit 0 ;; esac
COMPACT_AT=$((WINDOW * 85 / 100))   # where Grok auto-compacts
if [ "$COMPACT_AT" -le 150000 ]; then
    echo "ВНИМАНИЕ: на этой модели Grok сжимает контекст на 85% окна ($COMPACT_AT из $WINDOW), а это не выше минимального порога 150000 — STOP не сработает ни при каком допустимом пороге. Выберите модель с окном побольше или выполняйте план без паузы по контексту."
elif [ "$THRESHOLD" -ge "$COMPACT_AT" ]; then
    SUGGESTED=$((WINDOW * 8 / 10000 * 1000))          # 80% of the window, rounded down to thousands,
    [ "$SUGGESTED" -ge 150000 ] || SUGGESTED=150000   # but never below the floor
    echo "ВНИМАНИЕ: порог $THRESHOLD не ниже 85% окна контекста модели ($COMPACT_AT из $WINDOW) — Grok сожмёт контекст раньше, STOP не сработает. Задайте порог меньше, например /session-relay:do-plan $SUGGESTED."
fi
```

Its output is one `ВНИМАНИЕ:` line or nothing. Show the line to the user verbatim, then continue: it is a warning, not a reason to stop. Claude Code prints no window at all; skip this check there.

## Step 2 — Write per-session config file

The hook reads `~/.local/state/session-relay/do-plan-config-<cwd-encoded>-<session>.json` (`$XDG_STATE_HOME/session-relay/…` when that is set) to know the STOP threshold, where `<cwd-encoded>` is the absolute `pwd` with every `/` replaced by `-` and `<session>` is the current session id. The hook (`check-context-size.sh`) computes `<cwd-encoded>` from the same `pwd` encoding and the directory from the same `XDG_STATE_HOME` rule, so both sides land on one path under a marketplace install and under a `--plugin-dir` dev load alike. Session id: Claude Code uses the transcript filename stem; Grok uses `sessionId` / `$GROK_SESSION_ID` — this file's `SID` must be byte-equal to that key. Per-session keying lets two concurrent `/do-plan` runs in one cwd coexist without clobbering each other's threshold.

Use Bash:

```bash
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/session-relay"
mkdir -p "$STATE_DIR"
CWD_ENC=$(pwd | sed 's|/|-|g')

# Bind the hook to THIS session via a PER-SESSION config file
# do-plan-config-<cwd>-<session>.json. check-context-size.sh keys the file off
# the transcript stem when that file exists, else Grok sessionId / $GROK_SESSION_ID
# (see the hook). SID below must be byte-equal to that key. Per-session keying
# means two concurrent /do-plan runs in one cwd never clobber each other.
#
# No transcript-dir glob fallback (iter-1 review ISSUE-1/2): ~/.claude/projects/
# dir names encode '.'/'_'->'-' too (not just '/'), so a sed 's|/|-|g' glob misses
# on many real paths; and `ls -t | head -1` can pick another session's transcript
# under concurrency. No glob can identify "this" session, so fail loudly instead.
# Claude Code's Bash calls have CLAUDE_CODE_SESSION_ID; Grok has GROK_SESSION_ID
# and not the Claude var. Either one is enough; both empty cannot bind the hook.
SID="${CLAUDE_CODE_SESSION_ID:-${GROK_SESSION_ID:-}}"
[ -n "$SID" ] || { echo "/session-relay:do-plan: CLAUDE_CODE_SESSION_ID and GROK_SESSION_ID are both empty — cannot bind the context hook to this session. Aborting." >&2; exit 1; }

# Atomic write with jq (not printf): robust to a concurrent hook read seeing a
# half-written file. Session is in the filename, so the body is just the threshold.
CONFIG_PATH="$STATE_DIR/do-plan-config-${CWD_ENC}-${SID}.json"
CONFIG_TMP="$(mktemp "$STATE_DIR/.do-plan-config-${CWD_ENC}-${SID}.XXXXXX")" \
    || { echo "/session-relay:do-plan: mktemp failed for config" >&2; exit 1; }
jq -nc --argjson thr <THRESHOLD> '{stop_threshold:$thr}' > "$CONFIG_TMP" \
    && mv -f "$CONFIG_TMP" "$CONFIG_PATH"
```

Substitute `<THRESHOLD>` with the integer resolved in Step 1.

The per-session filename (`do-plan-config-<cwd>-<session>.json`) binds the hook to
this session: the hook reads the file named for its own session, so an ordinary
session in the same cwd (or a stale file from a past `/do-plan`) is never seen and
gets no milestone/STOP reminders. Two concurrent `/do-plan` runs in one cwd each
own their own file and don't clobber each other. On
`/session-relay:continue-plan-fresh-session`, the new session re-runs `/do-plan`,
which writes a file for the new session id.

## Step 3 — Confirm in one short line

Output a single status line so the user knows the threshold took effect, e.g.:

```
/session-relay:do-plan: STOP threshold = 400000 tokens. Dispatch model = <DISPATCH_MODEL>, full review rigor. Starting subagent-driven-development.
```

Substitute the resolved model: print `Dispatch model = <DISPATCH_MODEL>` when it is non-empty, or `Dispatch model = session-inherited` when `DISPATCH_MODEL` is empty.

No long preamble.

## Step 4 — Invoke the executor

Use the `Skill` tool with `skill = "superpowers:subagent-driven-development"`. That skill drives the per-task loop.

## Step 5 — Execution rules (overrides on top of the skill)

These apply throughout execution and override any cost-cutting guidance the skill might imply:

### Model: dispatch tier

- The dispatch model is `$DISPATCH_MODEL`, resolved in Step 1 from `dispatch_model` in the session-relay config, then (on Grok) dropped unless it is a live host slug. `echo "DISPATCH_MODEL=…"` in Step 1 is the value to use — already empty when the slug is not on this host.
  - **Non-empty** → every `Agent` / `spawn_subagent` dispatch (implementer, spec reviewer, code quality reviewer, parallel work, any subagent) **must explicitly set `model: "<DISPATCH_MODEL>"`**.
  - **Empty** (no `dispatch_model` in the config, no config file, or the configured slug is not a host model) → **omit `model:`** so each subagent **inherits this session's model**. Never explicitly pass a model *cheaper* than the session to economize on a "simple" subtask.
- spawn_subagent has no effort / `reasoning_effort` field. Do not invent one. Omitting `model:` is what inherits this session's reasoning effort (e.g. `xhigh` on `grok-4.6`) along with the model.
- The same dispatch-model rule applies to external reviewers (`superpowers:requesting-code-review` and friends) where a model parameter is accepted — set `model: "<DISPATCH_MODEL>"` when non-empty, otherwise omit it.
- If a subagent type does not accept a model override, accept the default — but do not deliberately route work to cheaper agents.

### Do not economize tokens

- Read source files in full when relevant to the task. Do not pre-truncate via `offset` / `limit` to "save context" unless the file is genuinely huge (multi-MB).
- Do not shorten or summarize subagent prompts to save input tokens. Pass full context.
- Do not skip optional verification commands to save time.

### Reviews are mandatory

- Per `superpowers:subagent-driven-development`, every task includes a **spec compliance review** and a **code quality review**. Never skip either, never short-circuit the re-review loop after a fix.
- This holds even if the task looks trivial.

## Step 6 — React to STOP (hook on Claude Code, `signals.json` on Grok)

### Claude Code — hook reminders

The `PostToolUse` hook injects system reminders of two kinds. These appear
**only** in the session where you started `/do-plan` (the hook is gated on the
per-session config file written in Step 2) — and for the rest of that session, even
after `/do-plan` finishes; in any other session (including an ordinary one in the
same cwd) it stays silent.

#### Milestone (informational)

```
ctx:150k
ctx:175k
ctx:200k
ctx:225k
…
```

Every 25k starting at 150k. **Do not change behavior.** Keep executing the plan. Do not even acknowledge the milestone in chat unless it carries STOP — these are passive situational awareness markers.

#### STOP signal (action required)

```
ctx:<N>k STOP threshold=<T>k - invoke /session-relay:pause-after-current-task
```

When you see this, follow **On STOP** below.

The STOP signal fires exactly once per session. If it has already fired and you somehow missed it, check that the hook's STOP-marker file (`~/.local/state/session-relay/context-stop-<session>.txt`) exists — but in normal flow, just trust the first reminder.

### Grok — poll `signals.json` (primary)

The harness knows the window (status line, `/session-info`, `/context`). **You do not:** those surfaces are not in the model context. The 0.14.x `PostToolUse` hook also does not deliver `ctx:…` here (Grok ignores that stdout). Do not wait for a hook reminder.

After each task reaches a clean checkpoint, **before dispatching the next task**, read the count. It is as of the last finished turn: Grok writes `signals.json` when a turn ends. Substitute the `CONTEXT_SIGNALS=` path echoed in Step 1 (a shell variable does not survive between Bash calls). If that echo was empty, re-glob:

```bash
grok_home="${GROK_HOME:-$HOME/.grok}"
SID="${GROK_SESSION_ID:-}"
CONTEXT_SIGNALS=""
[ -n "$SID" ] || { echo "CONTEXT_USED="; exit 0; }
for f in "$grok_home"/sessions/*/"$SID"/signals.json; do
    [ -f "$f" ] && CONTEXT_SIGNALS="$f" && break
done
if [ -z "$CONTEXT_SIGNALS" ]; then
    echo "ВНИМАНИЕ: signals.json не найден — STOP по порогу на этом чекпоинте не проверяем" >&2
    echo "CONTEXT_USED="
    exit 0
fi
VAL=$(jq -r '.contextTokensUsed // empty' "$CONTEXT_SIGNALS")
echo "CONTEXT_USED=${VAL}"
```

Compare the integer after `CONTEXT_USED=` to the STOP threshold from Step 1. If `>=` threshold, follow **On STOP** below. If the file is missing or the field is empty, the snippet prints one WARN on stderr and `CONTEXT_USED=` — keep going, do not invent a count.

Do not treat auto-compact (default 85% of the Grok window, often 425k on a 500k window) as the `/do-plan` threshold. Compact is later and is not a pause.

### On STOP

1. **Do not abort mid-task.** The current task must reach a clean checkpoint first.
2. Invoke the `pause-after-current-task` skill via the `Skill` tool. That skill encodes the entire state machine (implementer DONE → spec review ✅ → code review ✅ → mark complete in TodoWrite → checkpoint report).
3. Do **not** dispatch the next task.
4. Do **not** invoke `/session-relay:continue-plan-fresh-session` yourself — that is the user's manual action after they return.
5. After `pause-after-current-task` emits its standard checkpoint report, yield to the user.

## Step 7 — End of plan

If the plan reaches completion before STOP fires, follow `superpowers:subagent-driven-development` normally — final full-implementation review, `superpowers:finishing-a-development-branch`, and so on — with two additions below.

Offer the code review BEFORE `superpowers:finishing-a-development-branch`, and if the user
takes it, hold finishing entirely — no push, no PR, and no local merge either (finishing
deletes the branch after merging, and review fixes need somewhere to land) — until that
external review has run and its findings are applied. The order is the point: a
merged-and-deleted branch cannot absorb what the review finds.

Which external review to offer depends on what is installed. Inside herdr (`HERDR_ENV=1`),
`/herdr-review:review` launches it right here. With the mesh-review plugin installed,
`/mesh-review:code-review-fresh-session` writes the prompt for a fresh session, carrying the git
range and what only this session knows — deviations from the plan, what was left unfinished,
known weak spots. With neither, say so and offer the user's own review before finishing.

Whether this session can finish the branch is a fact to check, not to guess: run
`GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -oBatchMode=yes' timeout 8 git ls-remote --exit-code origin HEAD`
(or reuse a preflight verdict already printed in this session). Both guards earn their place:
without `BatchMode` a passphrase-protected key stops at a prompt and burns the whole budget
into a false "no network", and if `command -v timeout` finds nothing — stock macOS, where it is
not installed — the line exits 127, which is indistinguishable from a silent remote. Check for
`timeout` first and, when it is absent, say the reachability is unknown rather than reporting a
verdict; mesh-exec's `skills/shared/preflight-env.sh` has a dedicated branch for exactly this, and calls
such a verdict "invented out of a missing binary". If the remote does not answer, say plainly that
`superpowers:finishing-a-development-branch` cannot finish the job here: push and PR creation
need a network that is not available. Leave the branch for the user to finish outside. Do not
attempt the push to find out.

## Argument examples

- `/session-relay:do-plan` — threshold = `stop_tokens` from `~/.config/session-relay/config.yaml` (default 400 000)
- `/session-relay:do-plan 300k` — threshold 300 000 (one-shot override; written to per-session state)
- `/session-relay:do-plan 400000` — threshold 400 000 (override)
- `/session-relay:do-plan 1m` — **reject**, format unsupported (be strict)

## Bottom line

`/session-relay:do-plan` = "run the plan with full rigor; pause cleanly at the configured context threshold; let me come back later, run `/session-relay:continue-plan-fresh-session`, and resume". The user walks away, you grind through tasks autonomously, you stop at a clean checkpoint when context fills up.
