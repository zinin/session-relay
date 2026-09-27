"""Behavioral tests for the Codex adapter; live CLI smoke is separate."""
import concurrent.futures
import datetime
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
HELPER = REPO / "hooks/codex-context.py"


class CodexContext(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="sr-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = dict(os.environ, CODEX_SESSION_ID="parent-a", CODEX_THREAD_ID="parent-a",
                        XDG_STATE_HOME=str(self.root / "state"),
                        XDG_CONFIG_HOME=str(self.root / "config"))
        self.transcript = self.root / "rollout-parent.jsonl"
        self.write(140000)

    def record(self, kind, payload):
        return {"timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "type": kind, "payload": payload}

    def usage(self, count, **changes):
        info = {"last_token_usage": {"input_tokens": count - 100, "output_tokens": 100,
                                     "cached_input_tokens": count - 1000, "total_tokens": count},
                "total_token_usage": {"total_tokens": 9000000}, "model_context_window": 1000000}
        info.update(changes)
        return self.record("event_msg", {"type": "token_count", "info": info})

    def write(self, count, sid="parent-a", model="gpt-6-astra", source="cli", **changes):
        self.rows = [self.record("session_meta", {"id": sid, "source": source,
                      "cli_version": "0.157.1", "history_mode": "paginated"}),
                     self.record("turn_context", {"turn_id": "turn-a", "model": model}),
                     self.usage(count, **changes)]
        self.flush()

    def flush(self):
        self.transcript.write_text("".join(json.dumps(r) + "\n" for r in self.rows))

    def cli(self, *args, ok=True, env=None):
        p = subprocess.run(["python3", str(HELPER), *args], cwd=self.root,
                           env=env or self.env, text=True, capture_output=True)
        if ok:
            self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
        else:
            self.assertNotEqual(p.returncode, 0, p.stderr + p.stdout)
            return p.stderr + p.stdout
        return json.loads(p.stdout)

    def hook(self, event="PostToolUse", **changes):
        payload = dict(session_id="parent-a", cwd=str(self.root), hook_event_name=event,
                       transcript_path=str(self.transcript), model="gpt-6-astra", turn_id="turn-a")
        payload.update(changes)
        # Hook environment deliberately belongs to another session.
        env = dict(self.env, CODEX_SESSION_ID="outer", CODEX_THREAD_ID="outer")
        p = subprocess.run(["python3", str(HELPER), "hook"], cwd=self.root, env=env,
                           input=json.dumps(payload), text=True, capture_output=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        if not p.stdout:
            return ""
        output = json.loads(p.stdout)["hookSpecificOutput"]
        self.assertEqual(output["hookEventName"], event)
        return output["additionalContext"]

    def start(self, threshold="150k", env=None):
        p = self.cli("probe", threshold, env=env)
        receipt = self.hook(session_id=(env or self.env)["CODEX_SESSION_ID"])
        self.assertIn(p["run_id"], receipt)
        self.cli("arm", p["run_id"], env=env)
        return p["run_id"]

    def test_threshold_crossing_current_not_cumulative_and_once(self):
        run = self.start()
        self.assertNotIn("STOP", self.hook())
        self.write(150001)
        self.assertIn("STOP threshold=150000", self.hook())
        self.assertEqual(self.hook(), "")
        self.assertTrue(self.cli("check", run)["pause_required"])

    def test_parent_only_subagent_cannot_consume_stop(self):
        self.start()
        self.write(160000)
        self.assertEqual(self.hook(agent_id="child", agent_type="worker"), "")
        self.assertEqual(self.hook("SubagentStop"), "")
        self.assertIn("STOP", self.hook(tool_input={"agent_type": "worker"}))

    def test_restart_resets_stop_and_old_run_is_rejected(self):
        old = self.start()
        self.write(160000)
        self.assertIn("STOP", self.hook())
        new = self.start()
        self.assertNotEqual(old, new)
        self.assertIn("STOP", self.hook())
        self.assertIn("run", self.cli("check", old, ok=False))

    def test_two_sessions_in_one_cwd(self):
        a = self.start("150k")
        b_env = dict(self.env, CODEX_SESSION_ID="parent-b", CODEX_THREAD_ID="parent-b")
        self.write(160000, sid="parent-b")
        b = self.start("200k", b_env)
        self.assertNotIn("STOP", self.hook(session_id="parent-b"))
        self.write(160000)
        self.assertIn("STOP", self.hook())
        self.assertTrue(self.cli("check", a)["pause_required"])
        self.write(160000, sid="parent-b")
        self.assertFalse(self.cli("check", b, env=b_env)["pause_required"])

    def test_missing_untrusted_hook_requires_receipt(self):
        run = self.cli("probe", "150k")["run_id"]
        self.assertIn("/hooks", self.cli("arm", run, ok=False))

    def test_no_initial_usage_then_real_usage(self):
        self.rows.pop(); self.flush()
        run = self.cli("probe", "150k")["run_id"]
        self.assertNotIn("ready", self.hook())
        self.assertIn("usage", self.cli("arm", run, ok=False))
        self.rows.append(self.usage(140000)); self.flush()
        self.assertIn(run, self.hook())
        self.cli("arm", run)

    def test_ephemeral_wrong_thread_and_subagent_transcripts(self):
        run = self.cli("probe", "150k")["run_id"]
        self.assertNotIn("ready", self.hook(transcript_path=None))
        self.assertIn("transcript", self.cli("arm", run, ok=False))
        self.write(160000, sid="other")
        self.assertNotIn("ready", self.hook())
        self.write(160000, source={"subagent": {"thread_spawn": {"parent_thread_id": "parent-a"}}})
        self.assertNotIn("ready", self.hook())
        self.cli("arm", run, ok=False)

    def test_compaction_waits_for_real_usage_stop_survives(self):
        run = self.start()
        self.write(160000)
        self.assertEqual(self.hook("PreCompact"), "")
        self.rows.append(self.record("compacted", {}))
        self.rows.append(self.usage(5000, last_token_usage={"input_tokens": 0, "output_tokens": 0,
                                                           "total_tokens": 5000}))
        self.flush()
        self.assertEqual(self.hook("PostCompact"), "")
        self.assertTrue(self.cli("check", run)["pause_required"])
        self.assertIn("STOP", self.hook())
        self.assertEqual(self.hook(), "")

    def test_real_precompact_envelope_without_turn_id_latches_crossing(self):
        run = self.start()
        self.write(160000)
        self.assertEqual(self.hook("PreCompact", turn_id=None), "")
        self.hook("PostCompact", turn_id=None)
        self.write(10000)
        self.assertIn("STOP", self.hook())
        self.assertTrue(self.cli("check", run)["pause_required"])
        self.write(10000)
        self.assertEqual(self.hook(), "")
        self.assertTrue(self.cli("check", run)["pause_required"])

    def test_compaction_invalidates_old_usage_without_stop(self):
        run = self.start()
        self.hook("PreCompact"); self.hook("PostCompact")
        self.assertTrue(self.cli("check", run)["pause_required"])
        self.rows.append(self.record("compacted", {})); self.rows.append(self.usage(10000)); self.flush()
        self.hook()
        self.assertFalse(self.cli("check", run)["pause_required"])

    def test_stale_model_turn_and_unknown_data(self):
        run = self.start()
        old = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=10)).isoformat()
        self.rows[-1]["timestamp"] = old; self.flush()
        self.assertTrue(self.cli("check", run)["pause_required"])
        self.write(140000)
        self.assertNotIn("STOP", self.hook(model="different-model"))
        self.assertTrue(self.cli("check", run)["pause_required"])
        self.hook(model="gpt-6-astra", turn_id="new-turn")
        self.assertTrue(self.cli("check", run)["pause_required"])
        self.write(140000, last_token_usage={"total_tokens": 140000})
        self.hook()
        self.assertTrue(self.cli("check", run)["pause_required"])

    def test_partial_line_null_info_and_cached_tokens(self):
        run = self.start()
        self.rows.append(self.record("event_msg", {"type": "token_count", "info": None})); self.flush()
        with self.transcript.open("a") as f:
            f.write('{"type":')
        result = self.cli("check", run)
        self.assertEqual(result["used"], 140000)
        self.assertFalse(result["pause_required"])

    def test_rate_limit_repeat_cannot_refresh_age_turn_or_model(self):
        import copy
        run = self.start()
        old_usage = copy.deepcopy(self.rows[-1])
        self.rows[-1]["timestamp"] = (datetime.datetime.now(datetime.timezone.utc)
                                     - datetime.timedelta(minutes=10)).isoformat()
        self.rows.append(old_usage); self.flush()
        self.assertTrue(self.cli("check", run)["pause_required"])
        self.write(140000)
        self.rows.append(self.record("turn_context", {"turn_id": "turn-b", "model": "gpt-6-sol"}))
        self.rows.append(old_usage); self.flush()
        self.hook(turn_id="turn-b", model="gpt-6-sol")
        self.assertTrue(self.cli("check", run)["pause_required"])
        self.rows.append(self.usage(141000, total_token_usage={"total_tokens": 9141000})); self.flush()
        self.hook(turn_id="turn-b", model="gpt-6-sol")
        self.assertFalse(self.cli("check", run)["pause_required"])

    def test_invalid_threshold_config_window_and_ids(self):
        for arg in ["149k", "1m", "abc", "-1"]:
            self.cli("probe", arg, ok=False)
        self.cli("probe", "150K")
        config = self.root / "config/session-relay/config.yaml"
        config.parent.mkdir(parents=True)
        config.write_text("stop_tokens: 400k\n")
        self.assertIn(str(config) + ":1", self.cli("probe", "150k", ok=False))
        config.write_text("dispatch_model: grok-4.6\nstop_tokens: 150000\n")
        self.assertEqual(self.cli("probe")["dispatch_model"], "session-inherited")
        run = self.cli("probe", "1000k")["run_id"]
        self.hook()
        self.assertIn("window", self.cli("arm", run, ok=False))
        env = dict(self.env, CODEX_THREAD_ID="different")
        self.assertIn("ID", self.cli("probe", "150k", ok=False, env=env))
        env.pop("CODEX_SESSION_ID"); env.pop("CODEX_THREAD_ID")
        self.assertIn("ID", self.cli("probe", "150k", ok=False, env=env))

    def test_concurrent_hooks_deliver_one_stop(self):
        self.start(); self.write(160000)
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda _: self.hook(), range(4)))
        self.assertEqual(sum("STOP" in r for r in results), 1)

    def test_checkpoint_crossing_is_sticky_before_hook_delivery(self):
        run = self.start(); self.write(160000)
        self.assertTrue(self.cli("check", run)["pause_required"])
        self.write(10000)
        self.assertTrue(self.cli("check", run)["pause_required"])
        self.assertIn("STOP", self.hook())

    def test_finish_disarms(self):
        run = self.start(); self.cli("finish", run); self.write(160000)
        self.assertEqual(self.hook(), "")

    def test_child_identity_without_agent_field_does_not_poison_parent(self):
        run = self.start()
        child = self.root / "child.jsonl"
        self.write(180000, sid="child-id", source={"subagent": {"parent_thread_id": "parent-a"}})
        child.write_text(self.transcript.read_text())
        self.write(140000)
        self.assertEqual(self.hook(transcript_path=str(child)), "")
        self.assertFalse(self.cli("check", run)["pause_required"])

    def test_unknown_version_and_malformed_metadata_fail_clearly(self):
        run = self.cli("probe", "150k")["run_id"]
        self.rows[0]["payload"]["cli_version"] = "0.200.0"; self.flush()
        self.hook()
        self.assertIn("version", self.cli("arm", run, ok=False))
        self.rows[0]["payload"] = []; self.flush()
        self.hook()
        self.assertIn("metadata", self.cli("arm", run, ok=False))

    def test_explicit_identity_when_environment_has_no_ids(self):
        env = dict(self.env)
        env.pop("CODEX_SESSION_ID"); env.pop("CODEX_THREAD_ID")
        self.assertEqual(self.cli("probe", "150k", "--session-id", "parent-a", env=env)["session_id"], "parent-a")

    def test_installed_registration_handles_spaces_without_executable_bits(self):
        import shutil
        installed = self.root / "installed plugin"
        for directory in ("hooks", "skills/do-plan", ".codex-plugin"):
            shutil.copytree(REPO / directory, installed / directory)
        manifest = json.loads((installed / ".codex-plugin/plugin.json").read_text())
        registration = json.loads((installed / manifest["hooks"]).read_text())
        command = registration["hooks"]["PostToolUse"][0]["hooks"][0]["command"]
        (installed / "hooks/codex-context.py").chmod(0o600)
        run = self.cli("probe", "150k")["run_id"]
        payload = dict(session_id="parent-a", cwd=str(self.root), hook_event_name="PostToolUse",
                       transcript_path=str(self.transcript), model="gpt-6-astra", turn_id="turn-a")
        p = subprocess.run(["bash", "-c", command], cwd=self.root,
                           env=dict(self.env, PLUGIN_ROOT=str(installed)), input=json.dumps(payload),
                           text=True, capture_output=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn(run, json.loads(p.stdout)["hookSpecificOutput"]["additionalContext"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
