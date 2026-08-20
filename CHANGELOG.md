# Changelog

## 0.6.0 — 2026-08-20

### Added

- **The status line shows the current git branch.** New `branch` segment, on by
  default, so the bar reads `… | my-project | main`. Claude Code's status line payload
  carries a working directory, a worktree name and a repo slug, but no branch — so the
  segment reads `.git/HEAD` off disk rather than spawning `git branch --show-current`
  on every render. It walks up from the session's directory, follows the `gitdir:`
  pointer used by linked worktrees and submodules, keeps slashed names like
  `feature/nested/thing` whole, and prints a short sha when HEAD is detached. Outside a
  repository the segment is empty and drops out of the bar.

### Changed

- **`CONTEXT_CHECKER_STATUSLINE_SEGMENTS` now defaults to
  `ctx,model,session,limits,cwd,branch`.** Existing bars gain the branch on upgrade;
  set the variable without `branch` to keep the previous layout.

## 0.5.2 — 2026-07-30

### Corrected

- **0.5.1's stated reason for moving the shared marketplace was wrong.** It claimed
  Cowork excluded a plugin whose source resolves to the same repo as the marketplace
  listing it. Controlled testing (see `rig`'s CHANGELOG 1.28.2) disproved this: a
  throwaway repo holding `rig`'s exact content, referenced only by external URL from a
  marketplace that didn't share its repo, still failed in Cowork. The real cause is a
  top-level directory named `bin/` in `rig`'s own repo — unrelated to this plugin, to
  the marketplace move, or to self-reference. This plugin has no `bin/` directory and
  was never affected. The marketplace move itself (0.5.1, below) stands regardless —
  the real reason was a CLI-side `known_marketplaces.json` name collision, not Cowork.

## 0.5.1 — 2026-07-30

### Fixed

- **The shared `sito-plugins` marketplace was renamed.** ~~It lived in `itoh-shun/rig`,
  listing itself (source `./`, i.e. the marketplace's own repo) alongside this plugin
  (an external git URL). Cowork's plugin browser rendered only the externally-sourced
  entry — a marketplace's own repo, listed as one of its own plugins, silently dropped
  out whenever a sibling plugin didn't share that trait.~~ **Corrected in 0.5.2: this
  reasoning was wrong.** The real, still-valid reason: `rig` and this plugin had
  independently renamed their own marketplaces to `sito-plugins` on the same day, and
  Claude Code keys `known_marketplaces.json` by that name, so whichever was added last
  on the CLI silently overwrote the other's registration.

### Changed

- **The shared marketplace moved to a dedicated `itoh-shun/sito-plugins` repo** that
  holds nothing but a manifest listing `rig` and `claude-context-checker`, both by
  explicit external URL — so neither ever again shares a repo with the marketplace that
  lists it. `rig`'s own repo now hosts only its own single-plugin marketplace
  (`rig@rig`); see its README for details. The install command for this plugin is
  unchanged (`claude-context-checker@sito-plugins`) — only the marketplace source moves,
  from `itoh-shun/rig` to `itoh-shun/sito-plugins`.

## 0.5.0 — 2026-07-30

### Fixed

- **`PreCompact` silently stopped firing partway through a session.** Found while
  verifying checkpoint generation: `/compact` ran, tokens dropped as expected, but no
  checkpoint file appeared. `pre-compact.py` worked fine invoked directly, so the hook
  itself was not the problem — `claude --debug` logs showed why:

  ```
  [DEBUG] Plugin loading errors: Plugin claude-context-checker not found in marketplace sito-plugins
  ```

  This repo's marketplace had been renamed to `sito-plugins` in 0.4.0. An unrelated
  plugin (`rig`) independently renamed its own marketplace to the same name the same
  day. Claude Code keys `known_marketplaces.json` by marketplace name, so whichever
  repo was (re)added last silently overwrote the other's entry — after that point,
  this plugin dropped out of every hook-reload cycle, and `PreCompact` (along with
  every other hook) stopped being invoked. Nothing in this plugin's own code was
  broken; the install-time name simply stopped resolving to this repo.

### Changed

- **Marketplace renamed back to `claude-context-checker`.** The `sito-plugins` brand
  now lives canonically in the `rig` repo's marketplace, which lists this plugin as a
  second entry — so `sito-plugins` still works as an install target
  (`/plugin marketplace add itoh-shun/rig`), it is just no longer declared here too.
  Anyone who installed via this repo's own `sito-plugins` marketplace should remove it
  and re-add via either path in the README.
- Manual `statusLine` setup docs now point at the `cache/<marketplace>/claude-context-checker/<version>/`
  path rather than `marketplaces/<marketplace>/`, which resolves to the marketplace
  repo itself (someone else's code, when installed via a shared marketplace) rather
  than this plugin's files.

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
