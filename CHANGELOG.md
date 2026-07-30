# Changelog

## 0.2.0 — unreleased

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

## 0.1.0 — unreleased

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
