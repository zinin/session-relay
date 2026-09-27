# Codex context signal (2026-09-27)

The isolated Codex CLI 0.157.1 probe installed a local marketplace snapshot and ran
two shell calls. The plugin command expanded `CLAUDE_PLUGIN_ROOT` to its installed
cache directory. A nonce returned in `PostToolUse.additionalContext` appeared in the
model's final answer. Both shell ID variables matched the hook's JSON `session_id`;
the hook process's environment retained the **outer** session IDs. Hook input wins.

`thread/tokenUsage/updated` is an app-server client notification, not an input to a
command hook. This plugin has no subscription/connection to the owning app-server.
Starting another server would not observe this thread. The hook has `transcript_path`.

Use an isolated adapter for the unstable rollout JSONL format. Validate its
`session_meta.payload.id` against the exact hook ID; never select a newest file.
Use `event_msg/token_count.info.last_token_usage.total_tokens`, never
`total_token_usage` (cumulative billing), and never add cached input a second time.
In the probe, consecutive current counts were 14929, 15101, 15214; cumulative counts
were 14929, 30030, 45244. The first hook had no usage, the second had 14929: the
sample is from the last completed model request, delayed by a request/rollout flush.
It excludes tool results not yet sent to the model. It is not an instantaneous meter.

Codex source at `fcf05456bb` corroborates this: `TokenUsageInfo::append_last_usage`
replaces `last_token_usage` while adding to cumulative usage. After compaction,
`Session::recompute_token_usage` can emit a local estimate with zero input/output.
The adapter must invalidate samples at compaction and wait for a new real model
usage record (positive input, total = input + output). Model/turn changes and stale
samples also invalidate the old value. `PreCompact` checks for an already crossed
threshold before invalidating; a persisted STOP survives compaction.

The live compact events omit `turn_id`; retain the last parent tool's identity.
Compact hooks accept common output only, so they latch a crossing without stdout.
The next parent `PostToolUse` delivers it; checkpoint checks also latch crossings.
Full `token_count.info` can repeat on rate-limit updates: deduplicate by cumulative
and last usage together without refreshing the original timestamp. Cumulative
usage is used only to recognize a new measurement, never as context size.

Codex gets its own manifest/hook registration and state namespace. Claude/Grok
parsing, session keys and response envelopes stay separate. Before execution, a
fresh run nonce must be acknowledged through a real parent hook; installation alone
does not prove trust or execution. Missing/untrusted hooks, ephemeral transcripts,
unrecognized data, and thresholds outside the reported window fail explicitly.
At every task boundary the controller checks durable state and fresh usage before
dispatch; missing telemetry requires a clean pause, not unchecked continuation.

References: [Hooks](https://learn.chatgpt.com/docs/hooks),
[App server](https://learn.chatgpt.com/docs/app-server),
[Plugin packaging](https://developers.openai.com/plugins/build/plugins).
The transcript is explicitly not a stable hook API. Live validation results and
supported modes will be recorded separately from fixture tests.
