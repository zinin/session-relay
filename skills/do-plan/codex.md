# Codex controller

This adapter is verified on Linux for local Codex CLI **0.157.1**, with a persisted rollout
and trusted plugin hooks. Other versions fail explicitly until their transcript
format is verified. Ephemeral or remote sessions without a readable transcript are
unsupported. Use the loaded skill's actual directory to locate
`../../hooks/codex-context.py`; do not glob for another installed version.

## Startup

The shell and hooks must share a writable state directory. With `workspace-write`,
start Codex with `--add-dir "${XDG_STATE_HOME:-$HOME/.local/state}/session-relay"`
after creating that directory, or use a writable isolated `XDG_STATE_HOME` for the
whole Codex process. Report permission errors before dispatching; do not switch
only the shell to a different state location.

1. Resolve the helper's absolute path from this loaded skill. Run through `python3`
   (an executable bit is not required):

   ```bash
   python3 /absolute/loaded/plugin/hooks/codex-context.py probe 300k
   ```

   Replace `300k` with the invocation argument, or omit it for the config default.
   The helper validates the entire config even with an argument override. It prints
   a new `run_id`, threshold and `dispatch_model: session-inherited`. A configured
   `dispatch_model` is deliberately ignored on Codex, with a warning; omit both model
   and effort overrides for children. No Grok model catalogue is used.

   Session binding uses agreeing `CODEX_SESSION_ID` / `CODEX_THREAD_ID` values from
   **the parent model's shell**. These variables are observations, not a public API.
   If absent, pass `--session-id EXACT_ID` to every command only when that ID was
   supplied by this session's host context/hook. Conflicting IDs or no authoritative
   ID mean unsupported mode. Do not guess or read another session's latest file.

2. Wait for the separate hook context message
   `session-relay Codex ready run_id=<the same nonce> session_id=<this session> ...`.
   The JSON printed by `probe` is **not** this receipt. If there is no receipt, run
   `check <run_id>` in a **separate tool call**; its PostToolUse allows a previously
   buffered usage record to become visible. Retry at most twice across model
   responses, not a shell sleep loop. Before the first completed model request there
   may be no usage. A failed check supplies the exact reason.

   Without a matching receipt, do not arm or dispatch. Run `finish RUN_ID` (see
   Cleanup) so this run cannot announce itself later, then report the diagnostic and
   ask the user to inspect `/hooks`: plugin enabled, hook definitions trusted,
   `python3` present, installed script readable, and local transcript available.
   Installing a plugin does not trust its hooks. Do not bypass trust yourself.

3. After seeing the matching receipt, run:

   ```bash
   python3 /absolute/loaded/plugin/hooks/codex-context.py arm RUN_ID
   ```

   Preserve the literal run ID and absolute helper path for later calls. If
   compaction dropped the run ID, recover it with
   `python3 /absolute/loaded/plugin/hooks/codex-context.py status` (read-only: it
   prints the current run's `run_id`, `phase`, `threshold` and `stop_fired`), then
   continue with `check RUN_ID`. Never run `probe` to recover: a new probe starts a
   new run and discards the current run's STOP. Helper commands find the run by the
   session ID, so they work from any directory of the session, including a worktree.
   If `pause_required` is true, invoke `pause-after-current-task` before Task 1.
   Otherwise continue with do-plan Step 3 and Step 4. Announce that the counter is
   the last completed request and can lag by a request; don't call it instantaneous.

The threshold must be below 90% of the **reported usable window**, leaving margin
for Codex compaction. This is a conservative guard, not discovery of the actual
auto-compact limit: a user-configured lower limit can compact sooner. Never reduce
the requested threshold silently. After a model/window change the next check
revalidates the limit. If compaction wins before the threshold, STOP by threshold
has not occurred; wait for fresh post-compaction usage.

## At every checkpoint, before dispatching another task

```bash
python3 /absolute/loaded/plugin/hooks/codex-context.py check RUN_ID
```

Proceed only when the command succeeds with `phase: active`, empty `error`, and
`pause_required: false`. A STOP hook or `pause_required: true` means invoke
`pause-after-current-task`, complete the current task and its reviews, persist its
completion, and do not dispatch the next task. If telemetry is unavailable, retry
at most twice through separate model/tool calls for rollout buffering or compaction
recovery, then pause cleanly with the diagnostic. An earlier STOP remains sticky.
The hook reminds about unavailable telemetry only for persistent causes (version,
identity, format, window); transient gaps — stale, no usage yet, a turn or model
change, compaction — stay silent and surface through `check`.

The source is `token_count.info.last_token_usage.total_tokens`: input plus output
of the latest completed parent request. Cached input is already included. Lifetime
`total_token_usage` is never used. Tool results not yet sent to the model are not
included. Samples older than five minutes, from another model/turn, or invalidated
by compaction are unavailable. After compaction the adapter waits for measured
input/output; it rejects Codex's temporary local estimate. A long tool call may
therefore require a fresh request before a checkpoint can proceed.

`PreCompact` records a crossing before invalidation and emits no context. Only
the next parent `PostToolUse` delivers the pending STOP; `check` can see it sooner.
Repeating a full token-count record for a rate-limit update does not refresh its
age or make it belong to a different model/turn.

Read the plan's persisted progress before execution. At a reviewed checkpoint,
record completed task IDs, commits, checks and next unstarted task in the plan or
its adjacent progress file; use the available task tracker too. Commit the progress
with the checkpoint when commits are part of the plan. The continuation prompt
must name that file; a new session resumes from it, not from old hook state.

## Cleanup after a pause, a completed plan or a failed startup

```bash
python3 /absolute/loaded/plugin/hooks/codex-context.py finish RUN_ID
```

Do this after persisting progress, before the final report. Codex state is under
`${XDG_STATE_HOME:-~/.local/state}/session-relay/codex/`, keyed by the exact
session ID and locked during writes. A new `probe`, only for a new do-plan
invocation, creates a new nonce and resets STOP only for that run. Two sessions in
one cwd do not share state. Child hooks cannot write parent state. A checkpoint
check also detects a threshold crossing before hook delivery; it never consumes
the hook's one-time STOP.
