# session-relay

Run an implementation plan until the context fills up, pause at a clean checkpoint, and hand
the work to a fresh session. An [Agent Skills](https://agentskills.io) plugin for Claude Code
and Grok, installable in Codex. Split out of claude-mesh 0.15.0.

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
  Where neither signal exists — Codex, a bare terminal — do-plan refuses to start.
- **`/session-relay:pause-after-current-task`** — finish the current task in full (spec review,
  code review, fixes), then stop before the next one.
- **`/session-relay:continue-plan-fresh-session`**, **`/session-relay:exec-plan-fresh-session`**,
  **`/session-relay:transfer-session`** — write a prompt that resumes the plan, starts it, or
  carries any work over, in a fresh session. The prompt goes to a file under `docs/`; the chat
  gets only its path.

`do-plan` needs the [superpowers](https://github.com/obra/superpowers) plugin, `python3` (its
config reader) and `jq` (its state file and the context hook).

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

Codex gets the prompt generators and `pause-after-current-task`. `do-plan` refuses to start
there: Codex tells a session nothing about how full its context is.

Smoke-tested in `codex exec` 0.157: the generators wrote their files in a trusted folder or with
`-s workspace-write` (an untrusted folder gets a read-only sandbox); pause-after-current-task and
do-plan's refusal worked as described.

## Configure

Optional. `~/.config/session-relay/config.yaml` (`$XDG_CONFIG_HOME/session-relay/config.yaml`
when that is set); `config.example.yaml` is a starting point:

```yaml
stop_tokens: 400000    # STOP threshold in tokens, at least 150000
dispatch_model: opus   # model for do-plan's subagents; leave it out to inherit the session model
```

A mistake in the file stops do-plan with `<file>:<line>` instead of quietly using a default.
The state — the per-session threshold do-plan writes and the hook's markers — lives in
`~/.local/state/session-relay/` (`$XDG_STATE_HOME/session-relay`).

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
