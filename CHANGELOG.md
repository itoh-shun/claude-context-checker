# Changelog

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
