# session-relay

Run an implementation plan until the context fills up, pause at a clean checkpoint, and hand
the work to a fresh session. An [Agent Skills](https://agentskills.io) plugin for Claude Code
and Grok, with local Codex CLI 0.157.1 support (verified end-to-end through `codex exec` on
Linux). Split out of claude-mesh 0.15.0.

## Skills

- **`/session-relay:do-plan [threshold]`** — run the loaded plan through
  `superpowers:subagent-driven-development` and pause at a clean checkpoint once the session
  context crosses the STOP threshold: `stop_tokens` from the config (default 400000), or the
  argument for one run (`300k`, `400000`). Claude Code gets the signal from this plugin's
  `PostToolUse` hook, Grok from the session's `signals.json`, which Grok rewrites only when a
  turn ends. On Grok do-plan therefore sees the count as of the last finished turn: a run that
  stays in one turn — the usual case — does not pause (if it grows that far, Grok's auto-compact
  at 85% of the window comes first), and a fresh session's first turn has no count at all. Once
  `signals.json` exists, do-plan also warns when the threshold is not below 85% of the model's
  context window.
  Codex uses a separate parent hook and a checkpoint check of the last completed
  model request; see its setup and limits below. Unsupported hosts refuse to start.
- **`/session-relay:pause-after-current-task`** — finish the current task in full (spec review,
  code review, fixes), then stop before the next one.
- **`/session-relay:continue-plan-fresh-session`**, **`/session-relay:exec-plan-fresh-session`**,
  **`/session-relay:transfer-session`** — write a prompt that resumes the plan, starts it, or
  carries any work over, in a fresh session. The prompt goes to a file under `docs/`; the chat
  gets only its path.

`do-plan` needs the [superpowers](https://github.com/obra/superpowers) plugin and `python3`.
Claude Code and Grok also need `jq` for state and context hooks.

## Install

### Claude Code

```
/plugin marketplace add zinin/agent-plugins
/plugin install session-relay@zinin
```

### Grok

Nothing to do when Claude Code has it: Grok loads the plugins Claude Code installed. Without
Claude Code: `grok plugin marketplace add zinin/agent-plugins`, then
`grok plugin install session-relay --trust`.

### Codex

```
codex plugin marketplace add zinin/agent-plugins
codex plugin add session-relay@zinin
```

Enable the plugin, then open **`/hooks`** in Codex and review/trust its hook definitions.
Installation alone does not grant hook trust. Start a new session after installing
or updating; changed hook definitions may need trust again. Python 3 and a readable
local transcript are required. Hook commands invoke Python explicitly, so executable
bits on packaged scripts are not required. Codex's separate manifest loads
`hooks/codex-hooks.json`; Claude Code and Grok retain `hooks/hooks.json`.

In `workspace-write`, allow the state directory for the model's shell too (hooks
and shell must use the same `XDG_STATE_HOME`):

```bash
mkdir -p "${XDG_STATE_HOME:-$HOME/.local/state}/session-relay"
codex --add-dir "${XDG_STATE_HOME:-$HOME/.local/state}/session-relay"
```

An unwritable directory fails startup; do-plan does not report a working monitor.

Invoke `$session-relay:do-plan 150k` (or the host's slash-command equivalent).
Before dispatching, do-plan requires a fresh nonce returned by the **parent hook**
and validates the counter and window. If the receipt is missing it reports a
concrete diagnostic: inspect `/hooks`, plugin enablement, Python and transcript
access. It does not declare automatic pause active on installation alone.

The adapter currently accepts **CLI 0.157.1** rollout JSONL. It reads
`event_msg/token_count.info.last_token_usage.total_tokens` for the exact hook
`session_id`, verified against `session_meta.id`. This is input plus output of the
last completed model request, including cached input once; lifetime
`total_token_usage` and child usage are not the context counter. Hooks receive no
`thread/tokenUsage/updated` subscription. The transcript format is unstable, so
other CLI versions fail explicitly pending verification. After a Codex update,
do-plan refuses with `unverified Codex transcript version` until a session-relay
release verifies the new format; use CLI 0.157.1 for do-plan meanwhile. The version
comes from the rollout's `session_meta`, i.e. the CLI that created the session: run
do-plan in a session started by 0.157.1, not one resumed across CLI versions.

There is a request/flush delay: a first hook can have no count, and tool results
not yet sent to the model are not counted. Startup retries across model responses;
each task boundary checks again before dispatch. Samples older than five minutes,
from another turn/model, or invalidated by compaction are unavailable. After
compaction, Codex's temporary estimate is rejected until measured usage arrives.
An already crossed STOP survives compaction and fires once per run. A new run has
a new nonce; two threads in one directory have independent state.

Keep the threshold below 90% of the reported usable window (a conservative margin).
The default 400000 can exceed a model's window: choose an explicit lower threshold
or a larger window; do-plan never silently lowers it. A lower Codex auto-compact
setting can still compact before STOP. Missing telemetry at a checkpoint requires
a clean pause after bounded retries. This is a cooperative controller, not a hard
token-budget interrupt; the current task and reviews can grow beyond the threshold.

Ephemeral sessions, remote transcripts unavailable locally, missing session identity,
untrusted/disabled hooks and unrecognized versions/formats are unsupported.
`CODEX_SESSION_ID` / `CODEX_THREAD_ID` are observed shell hints, not a promised API;
when absent an exact ID supplied by the current host context is required. No newest
session-file lookup is used.

## Configure

Optional. `~/.config/session-relay/config.yaml` (`$XDG_CONFIG_HOME/session-relay/config.yaml`
when that is set); `config.example.yaml` is a starting point:

```yaml
stop_tokens: 400000    # STOP threshold in tokens, at least 150000
dispatch_model: opus   # Claude; checked on Grok; Codex warns and inherits its session model
```

A mistake in the file stops do-plan with `<file>:<line>` instead of quietly using a default.
The state — the per-session threshold do-plan writes and the hook's markers — lives in
`~/.local/state/session-relay/` (`$XDG_STATE_HOME/session-relay`). Codex has a separate
`codex/` namespace and disarms it after a pause/completion. Reviewed task progress
is saved in the plan or an adjacent progress file so a fresh session skips done tasks.
Codex validates `dispatch_model` syntax but deliberately ignores the value, warns,
and inherits the parent's model and reasoning effort through its actual subagent
tool schema. Grok-specific models and fields are never sent to Codex tools.

### Moving from claude-mesh

`runtime.do_plan_default_stop_tokens` and `runtime.dispatch_model` in the claude-mesh config are
not read here. The default threshold was 250000 there and is 400000 here; set `stop_tokens`
for the old value, and `dispatch_model` if you had one.

## Grok follow-up

do-plan's STOP on Grok reads `signals.json`, which Grok 1.0.41 writes only when a turn ends. The
session's `updates.jsonl` gains `_meta.totalTokens` on every update, mid-turn; in the 2026-09-26
smoke its last value equalled `signals.json`'s `contextTokensUsed` at turn end. Reading the last
`_meta.totalTokens` in do-plan's Step 6 poll and window check, with `signals.json` as the fallback,
would let STOP fire inside one turn. Tracked for a separate change.

## Tests

`for f in tests/test-*.sh; do bash "$f"; done`

## License

MIT — see [LICENSE](LICENSE).
