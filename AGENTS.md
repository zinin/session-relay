# session-relay (plugin source)

This file is for work inside this repository. It is not a plugin component.

## Load the working tree

- **Claude Code**, this session only: disable a marketplace copy first
  (`claude plugin disable session-relay@zinin`), then `claude --plugin-dir "$PWD"`; re-enable it
  afterwards.
- **Grok** has no `--plugin-dir` in interactive mode: `grok plugin install "$PWD" --trust`
  copies a snapshot to `~/.grok/installed-plugins/session-relay-<hash>`. Grok names the
  snapshot after the source directory, so install from a directory named `session-relay`:
  do-plan finds its `read-config.py` under `installed-plugins` by that name and would otherwise
  fall back to the marketplace copy. After a change,
  `grok plugin uninstall session-relay --confirm` and install again, then start a new session.
  Keep exactly one snapshot: `ls -d ~/.grok/installed-plugins/session-relay-*` lists one entry.

## While working in this repo

- Agents never edit the user's `~/.config/session-relay/config.yaml`.
- Do not bump `.claude-plugin/plugin.json` on a feature branch; a release is a separate
  `chore(release): X.Y.Z` commit on master with an annotated tag `session-relay--vX.Y.Z`.
- Before a PR: `git rm -r docs/superpowers/` when it exists, and commit.
- Tests: `for f in tests/test-*.sh; do bash "$f"; done`.
