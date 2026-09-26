# Changelog

All notable changes to session-relay will be documented here.

## [Unreleased]

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
- **do-plan's end-of-plan review offer** names `/herdr-review:review` or the mesh-review plugin,
  whichever is there, instead of `/claude-mesh:code-review-fresh-session`.
