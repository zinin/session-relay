# Codex validation — 2026-09-27

## Environment and scope

Linux x86_64, `codex-cli 0.157.1`, model `gpt-6-astra`, local persisted
`codex exec` sessions with paginated history. The source checkout used to inspect
Codex internals was `fcf05456bb` (2026-09-17); observed CLI behavior takes precedence
over that checkout and documentation when they differ.

Experiments used `/tmp/sr-codex-probe-1tguwh0b/`: a separate `CODEX_HOME`, local
marketplace, installed snapshots, Git repositories, `XDG_CONFIG_HOME` and
`XDG_STATE_HOME`. The temporary home linked the existing auth file without reading
or copying its contents. No user session-relay settings were changed. Authenticated
model requests required network access outside the outer filesystem sandbox.

The tested hook sources were reviewed before using the per-invocation
`--dangerously-bypass-hook-trust` test flag. That flag did not persist trust; the
negative trust test omitted it. Production instructions require `/hooks` review.

## Observed transport and counter

- Installed marketplace copy: `${CLAUDE_PLUGIN_ROOT}` and `${PLUGIN_ROOT}` both
  resolve to its cache directory. The production Codex manifest selects its own
  hook file and Python entry point. A fixture additionally checks a path containing
  spaces and an entry point without executable permission.
- A real `PostToolUse` hook returned nonce `sr-live-7ec3` through
  `hookSpecificOutput.additionalContext`; the parent model repeated it in its final
  answer. This proves delivery, independently of fixture tests.
- The shell's `CODEX_SESSION_ID` and `CODEX_THREAD_ID` equalled JSON `session_id`.
  The hook process inherited the outer session's environment IDs. The implementation
  therefore uses **JSON input only** in hooks and validates transcript metadata.
- A first hook had no token count. The second had the preceding request's count.
  Successive last-request totals were **14929 → 15101 → 15214**; corresponding
  lifetime totals were **14929 → 30030 → 45244**. Only the first series measures
  the last completed request's context. Cached input is included once.
- No app-server connection or subscription is exposed to this command plugin.
  `thread/tokenUsage/updated` is delivered to app-server clients; it is absent from
  hook input. Starting another app-server is not a subscription to this session.
- Real compaction with `model_auto_compact_token_limit=18000` emitted PreCompact,
  PostCompact and SessionStart. Before compaction: **15055**; immediately after:
  **8344**, with input/output both zero (a local estimate). The adapter rejects that
  estimate until real usage appears. Compact payloads lacked `turn_id`; compact
  outputs do not support `additionalContext`. The implementation preserves identity,
  latches STOP without output there, and delivers through the next parent tool.
- Code inspection found full `token_count.info` repeats on rate-limit updates.
  Tests verify such repeats cannot refresh an old measurement's age/model/turn.

## Live scenarios

| Scenario | Result |
|---|---|
| Baseline 0.16.0 Step 1 in Codex shell | Refuses before config read: no Claude/Grok signal |
| Installed diagnostic hook, two real shell calls | Root expansion, matching IDs and parent receipt confirmed |
| Real compaction transport probe | Old count, estimate and event payload differences confirmed |
| Production adapter through real compaction | Armed at 16154; first recovery check rejected the estimate, second accepted 16853 with `pause_required=false`; finished without fabricated STOP |
| Installed plugin without hook trust | Refuses with `hook receipt missing; check installation and trust via /hooks`; no tasks dispatched |
| Trusted plugin in `codex exec --ephemeral` | Refuses with `no transcript_path (ephemeral/remote mode is unsupported)`; no tasks dispatched |
| First synthetic plan attempt | **Not a successful E2E**: default `exec` policy blocked Git writes; one huge calibration output was truncated; threshold not crossed, reviews not run |
| Installed plugin, real 150000 crossing in Task 1 | **Passed**: 143310 below → 151904 above; exactly one parent STOP, Task 1 and both reviews completed, progress committed, Task 2 not dispatched, run disarmed |
| Fresh-session continuation | **Passed**: Task 1 skipped, Task 2 implemented/reviewed/committed, final review approved, progress saved and run disarmed |

The successful crossing run was thread `01a0e2e8-0686-7641-ad39-3b744b4edf8a`,
run nonce `1651da09a4e94cde94fc052c1efa57dc`. Its parent performed 12 sequential
calibration reads while Task 1 was active; STOP arrived on read 8. Task 1 commit:
`e215881`; checkpoint commit: `8ca12ba`. Separate `task1_spec` and `task1_quality`
reviewers approved. The final checkpoint measured 205616 tokens and reported
`pause_required=true`. The tree was clean, Task 2's artifact absent and state
`phase=finished`. This is a real model run, not a fixture-driven E2E claim.

The fresh continuation used thread `01a0e2ec-d7d3-76b1-a7e5-1b77ad9341d6`,
nonce `b199bd04cc024570b5333584c63b38d1`. Its pre-Task-2 check measured 35426 tokens
and allowed dispatch. Task 2 commit: `8edadc5`. The only children were
`task2_implementer`, `task2_review` (spec and quality), and `final_review`; Task 1 and
its calibration were not repeated. Progress records all tasks complete and cleanup
returned `phase=finished`.

Direct rollout inspection found exactly **one** STOP developer message in the
crossing parent and **zero** in all three children. All spawns omitted model and
effort overrides; parent and children used `gpt-6-astra`. The continuation parent
and its children received zero STOPs. These observations validate model inheritance,
parent-only delivery and fresh-session progress independently of their final reports.

Remote/IDE/cloud modes, other models and other CLI versions have not been certified
by these experiments. Concurrent threads in the same cwd, repeated invocations,
stale/malformed counters, changed model/window and configuration errors are covered
by deterministic tests, not claimed as additional live model experiments.

## Reproduction

1. Use a temporary Codex home with access to existing credentials, an isolated XDG
   config/state location, and a temporary Git repository. Do not copy user hooks or
   modify user config. Install source snapshots of session-relay and superpowers
   through a local marketplace using `codex plugin marketplace add` and
   `codex plugin add`. Reload/reinstall the snapshot after source changes.
2. Enable hooks and review their sources. For this disposable harness only, the
   trust bypass flag above skips interactive trust review. Ordinary installs use
   `/hooks`. Let the model inherit its configured model/effort for all subagents.
3. Run `codex exec --approve-for-me --json` with `$session-relay:do-plan 150k` and
   an approved two-task plan. Task 1 writes a marker, commits it, runs both reviews,
   and persists progress. Task 2 writes a different marker.
4. Supply inert calibration text as real input, then have the parent read successive
   500-line portions of a 6000-line calibration file while Task 1 is in progress.
   Use separate tool calls: a single enormous output can be truncated. Keep all
   calibration data outside the plugin source and out of child contexts. Never
   lower the 150000 floor or inject a fake counter/STOP.

   The successful run used these inputs (plain data, no forged telemetry):

   ```python
   appendix = "alpha " * 58000
   payload = "".join(
       f"{i}: alpha beta gamma delta epsilon zeta eta theta iota kappa\n"
       for i in range(6000)
   )
   ```

   Each tool requested `max_output_tokens=9000`; ranges were `1,500`, `501,1000`,
   through `5501,6000`. STOP during these reads still permits finishing all reads
   and both reviews, because they are part of the current task.
5. Inspect the parent's actual rollout, durable state, review results and Git log.
   Verify a below-threshold sample, a real crossing, exactly one developer STOP,
   no child receipt/STOP, completed reviewed Task 1 and absent Task 2. Start a fresh
   session referencing the persisted progress and verify it resumes at Task 2.

Raw local experiment artifacts are in the temporary directory above (`exec-live`,
`compact`, `compact-adapter`, `smoke`, `crossing`, `continuation`, `untrusted`, `ephemeral` JSONL/stderr pairs and isolated
rollouts). They contain generated calibration/context and are not shipped as fixtures.

## Automated tests and limitations

`for f in tests/test-*.sh; do bash "$f"; done`: **138 checks, zero failures**, including
21 Codex tests and all Claude/Grok/config/model-catalog regressions. Per-file exit
codes were checked; `git diff --check` and Python syntax checks also passed.

Fixture coverage includes startup receipt, absent/invalid/stale usage, partial JSONL,
cached input, duplicate full info, model/turn changes, compaction, parent/child,
concurrent hooks, two threads, restart, durable checkpoint crossing, config errors,
window limits, missing IDs, installed path quoting and script permissions.

The JSONL format is unstable and version-gated. The signal lags by a completed
request/flush and excludes tool output not yet sent to the model. Five-minute-old
data is unavailable. Compaction can happen before a threshold, particularly with a
lower host limit or an oversized tool result; the plugin does not invent a measured
crossing. A reliable future API should give parent/thread identity, current context
usage, model/window, measurement generation and compaction generation directly to
hooks (including ephemeral sessions), with an explicitly supported delivery event.

Official references: [Hooks](https://learn.chatgpt.com/docs/hooks),
[App server](https://learn.chatgpt.com/docs/app-server),
[Plugin packaging](https://developers.openai.com/plugins/build/plugins).

## Changed files

- `.codex-plugin/plugin.json`, `hooks/codex-hooks.json`: separate Codex registration.
- `hooks/codex-context.py`, `hooks/codex-transcript.py`: handshake, state, adapter,
  checkpoint fallback and parent-only delivery.
- `hooks/check-context-size.sh`: comments reflecting per-invocation reset; legacy
  parsing and output are unchanged. `hooks/hooks.json` is unchanged.
- `skills/do-plan/SKILL.md`, `skills/do-plan/codex.md`: host routing, executor/tool
  adaptation, startup, threshold, dispatch model, checkpoint and cleanup rules.
- `skills/pause-after-current-task/SKILL.md`,
  `skills/continue-plan-fresh-session/SKILL.md`: persistent progress and host tracker
  adaptation for continuation.
- `tests/test-codex-context.sh`, `tests/codex_context_test.py`, `tests/test-do-plan.sh`:
  behavioral coverage and replacement of the old blanket Codex refusal test.
- `README.md`, `config.example.yaml`, `docs/codex-context-design.md`,
  `docs/codex-validation.md`: setup, contract, evidence and limits.

`skills/do-plan/read-config.py` and `.claude-plugin/plugin.json` were not changed;
configuration validation and the existing release version remain intact. The task
prompt under `docs/2026-09-27-codex-do-plan-support-prompt.md` was left untouched.
