# Changelog

## 0.4.1 — 2026-07-30

### Fixed

- **Crash on a Japanese Windows console.** Python follows the console code page,
  which is cp932 there, and cp932 has no `·` (U+00B7) — the separator used in
  `high·think` and in every subagent row. Printing raised `UnicodeEncodeError` and
  the hook died:

  ```
  UnicodeEncodeError: 'cp932' codec can't encode character '\xb7'
  ```

  This was not limited to the separator: any project directory with a non-ASCII
  name hit the same wall.

- **Payloads with non-ASCII content were dropped on the way in.** The same code
  page applies to stdin, so a payload carrying a Japanese directory name or session
  title failed to decode, json parsing raised, and the hook returned having done
  nothing — no error, no output, no warning. Found while writing the test for the
  bug above, which is why the fix covers both directions.

  Hooks now read the raw stdin buffer and decode UTF-8 explicitly, and reconfigure
  stdout and stderr to UTF-8 with `errors="replace"`, so the console encoding is out
  of the loop entirely.

  Verified on the Windows machine that reported it, and pinned by five assertions
  that run the hooks under `PYTHONIOENCODING=cp932` with Japanese payloads.

## 0.4.0 — 2026-07-30

### Fixed

- **The hooks never ran on Windows.** `python3` there is normally the Microsoft
  Store alias: it writes `Python was not found` to stderr, exits 49, and executes
  nothing, while the working interpreter is `python`. Every hook was wired to
  `python3`, so all three failed with no visible symptom. Measured on a Windows box
  with Python 3.12.10 installed:

  | Command | Result |
  | --- | --- |
  | `python3 statusline.py` | `Python was not found`, exit 49 |
  | `sh run.sh statusline.py` | renders normally |

  Commands now go through `hooks/run.sh`, which probes `python3`, `python`, then
  `py`, and honours `CONTEXT_CHECKER_PYTHON` as an explicit override. The probe has
  to happen before the hook reads stdin — Claude Code pipes the payload in once, so
  a "try `python3`, fall back to `python`" chain would hand the second attempt an
  empty stream. That is why this is a launcher rather than a shell one-liner.

  Quoted paths survive in both `C:/...` and `C:\...` form, so the documented Git Bash
  backslash hazard does not apply here.

### Changed

- **Marketplace rebranded to `sito-plugins`**, so future plugins share one brand:

  ```
  /plugin marketplace add itoh-shun/claude-context-checker
  /plugin install claude-context-checker@sito-plugins
  ```

  The plugin name is unchanged. Anyone on 0.3.0 should remove the old
  `claude-context-checker` marketplace and re-add it.
- The documented `statusLine` command now uses `run.sh` too, so the same line works
  on Windows, Linux, and macOS.

### Added

- Test 18 covers the launcher, including a stub that reproduces the Windows Store
  alias behaviour (stderr, exit 49, reads no stdin) to prove it is skipped rather
  than accepted.

## 0.3.0 — 2026-07-30

### Changed

- **Renamed to `claude-context-checker`**, matching the repository. This changes the
  install command and is why the version bumps rather than the v0.2.0 tag moving:

  ```
  /plugin install claude-context-checker@claude-context-checker
  ```

  Anyone on 0.2.0 needs to uninstall `context-checker@context-checker` and install
  under the new name.

  Runtime paths and environment variables keep the `context-checker` prefix
  (`~/.claude/tmp/context-checker/`, `CONTEXT_CHECKER_*`), so existing state and
  configuration survive the rename.

### Notes

- The subagent status line is now documented as unverified in a live agent panel.
  Its script and its declared command string are covered by tests, but whether
  Claude Code loads a plugin's `settings.json` was not confirmed — `claude --debug`
  emits no plugin-load lines to check against. If it is not picked up, agent rows
  keep their default rendering; nothing breaks.

## 0.2.0 — 2026-07-30

### Added

- **Subagent status line.** Each agent row shows a percentage of that agent's own
  context window instead of a raw token count, which cannot be read without knowing
  the window it sits in. Shipped in the plugin's `settings.json`, so unlike the main
  status line it needs no manual setup. Rows whose model is not resolved yet keep
  their default rendering rather than showing an invented figure.
- **Thresholds follow the auto-compact point.** With `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`
  set, notice fires 15 points below it and critical 5 points below, so the critical
  warning can no longer arrive after the compaction it exists to pre-empt. The status
  line shows the point it is working against (`ctx 62% → auto 70%`), and an explicit
  `CONTEXT_CHECKER_*_PCT` still wins.
- **Session state and plan limits in the status line**: effort level, extended
  thinking, fast mode, and the 5-hour / 7-day usage windows. Segments are selectable
  via `CONTEXT_CHECKER_STATUSLINE_SEGMENTS`; plan limits can be hidden until they
  matter with `CONTEXT_CHECKER_RATE_LIMIT_MIN_PCT`.
- The smoke test now runs the command strings from both `hooks.json` and
  `settings.json` through a shell with `${CLAUDE_PLUGIN_ROOT}` set, and asserts they
  fail without it — proving the substitution is load-bearing rather than incidental.

### Changed

- Percentages render without a trailing `.0` (`80%`, not `80.0%`).
- The smoke test clears `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` and every
  `CONTEXT_CHECKER_*` variable, so a tester's own configuration cannot change results.

### Notes

- Advisor state was considered and dropped: it does not appear anywhere in the status
  line payload, which was confirmed by capturing a live one rather than reading docs.
  The same capture confirmed effort, thinking, fast mode, and rate limits are present.

## 0.1.0 — 2026-07-30

First packaged release, extracted from a personal `~/.claude/hooks/context-monitor`
setup where only the status line had ever been wired up.

### Added

- Claude Code plugin packaging: `hooks/hooks.json` wires `UserPromptSubmit`,
  `PreCompact`, and `PostCompact` through `${CLAUDE_PLUGIN_ROOT}`, so no path editing
  is needed. The `context-checkpoint` skill ships with it.
- `tests/smoke.sh`: runs every hook against mock payloads in a throwaway `HOME`.
- Threshold, state TTL, and context window size are configurable via environment.
- Stale per-session state files are pruned (previously they accumulated forever).
- The `UserPromptSubmit` hook reports once per session when no usage figure is
  available, instead of silently doing nothing.

### Fixed

- Read `context_window.used_percentage`, `context_window_size`, and
  `total_input_tokens`. The previous code read `context_window.input_tokens`, which
  does not exist — every recorded value was `null`.
- Use `model.display_name` rather than splitting the model id on `-`, which rendered
  `claude-opus-5` as `opus`.
- `PostCompact` now resets the threshold state, so a crossing after compaction warns
  again rather than being suppressed by the pre-compact level.

### Notes

- The main status line cannot be provided by a plugin — only `subagentStatusLine` is
  supported — so it stays a documented manual step.
- The transcript-based usage estimate requires an explicitly declared window size.
  Inferring it from the model id was tried and rejected: measured against 53 real
  sessions it was off by more than 70 points, warning CRITICAL at 19% actual usage.
  With the correct window the same formula lands within 1 point on 52 of 53.
