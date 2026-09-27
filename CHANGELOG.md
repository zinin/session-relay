# Changelog

All notable changes to session-relay will be documented here.

## [Unreleased]

### Added
- **do-plan runs in local Codex CLI 0.157.1.** A Codex-only manifest loads
  `hooks/codex-hooks.json`, whose parent hook reads the last completed request's usage from the
  session's rollout. Startup waits for the parent hook's receipt (trust the hooks in `/hooks`),
  STOP survives compaction and fires once per run, `dispatch_model` is ignored on Codex
  (subagents inherit the session model), and unverified session-creation versions refuse.
  The current executable's version is not checked; use 0.157.1 throughout a session.

### Changed
- **On Claude Code and Grok, STOP fires once per do-plan invocation rather than once per
  session.** Step 2 clears the previous STOP and milestone markers.

## [0.16.0] - 2026-09-27

### Changed
- **Split out of claude-mesh 0.15.0.** `do-plan`, `pause-after-current-task`, `transfer-session`,
  `exec-plan-fresh-session` and `continue-plan-fresh-session` moved here with their history and
  became skills — `/session-relay:do-plan` and so on — because Codex loads skills, not commands.
- **A config of its own: `~/.config/session-relay/config.yaml`** with `stop_tokens` (default
  400000; claude-mesh's `runtime.do_plan_default_stop_tokens` defaulted to 250000) and
  `dispatch_model`. `read-config.py` reads it without `yq`; a mistake stops do-plan with
  `<file>:<line>`.
- **State under `~/.local/state/session-relay/`**, one path for the hook and do-plan under
  every harness. Under a `--plugin-dir` load the hook used to read another plugin-data
  directory than the one do-plan wrote, and STOP never fired.
- **do-plan refuses to start without a context signal** (Codex, a bare terminal), and on Grok
  warns when the threshold is at or above 85% of the model's context window: auto-compact comes
  first, so STOP never fires. The threshold it suggests instead is never below 150000.
- **On Grok, do-plan's window check runs once `signals.json` exists.** Grok writes it when a
  turn ends, so a session's first turn has no window to check; the check runs at the first task
  checkpoint that finds the file. The STOP poll's count is as of the last finished turn, so a
  run that stays in one turn does not pause on Grok (a live count is a follow-up — README,
  "Grok follow-up").
- **do-plan's end-of-plan review offer** names `/herdr-review:review` or the mesh-review plugin,
  whichever is there, instead of `/claude-mesh:code-review-fresh-session`.
