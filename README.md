# claude-context-checker

Watch the context window, and survive compaction.

A Claude Code plugin that shows how full the context window is, warns once when it
gets tight, and writes a checkpoint of what you were doing right before the
transcript is summarized away — so a compaction never silently drops the thread.

日本語版は [README.ja.md](README.ja.md)。

## What it does

| Component | Event | Behaviour |
| --- | --- | --- |
| `statusline.py` | status line | Renders context usage, the auto-compact point, model, effort, and plan limits — and records the usage figure for the hooks to read |
| `subagent-statusline.py` | subagent status line | Replaces each agent row's raw token count with a percentage of that agent's own context window |
| `prompt-submit.py` | `UserPromptSubmit` | Injects one warning per threshold crossing. Never repeats within the same level |
| `pre-compact.py` | `PreCompact` | Writes a markdown checkpoint: recent user messages verbatim, truncated assistant replies, files edited, commands run |
| `post-compact.py` | `PostCompact` | Tells Claude where that checkpoint is, so anything the summary dropped can be recovered |
| `context-checkpoint` | skill | Prepares a structured checkpoint and drafts a `/compact <instructions>` string. You decide whether to run it |

Python 3 standard library only. No dependencies, no network calls.

```
[WARN] ctx 62% → auto 70% | Opus 5 (1M context) | high·think | 5h 27% · 7d 35% | my-project
```

```
[OK]   Explore · search auth flow · 6%
[WARN] code-reviewer · review diff · 62%
```

The second block is the agent panel. `48.1k` tokens tells you nothing on its own —
it is comfortable on a 1M window and nearly half of a 200k one — so each row shows
the ratio instead, using the same thresholds as the main bar.

## Install

### 1. Add the plugin

```
# via the shared sito-plugins marketplace (recommended — also hosts the rig plugin)
/plugin marketplace add itoh-shun/sito-plugins
/plugin install claude-context-checker@sito-plugins

# or directly from this repo, no shared marketplace involved
/plugin marketplace add itoh-shun/claude-context-checker
/plugin install claude-context-checker@claude-context-checker
```

> Upgrading from 0.4.x: this repo's own marketplace was briefly named `sito-plugins`
> too, until it collided with an unrelated plugin (`rig`) claiming the same name —
> Claude Code keys installs by marketplace name, so whichever was added last silently
> took over the other's registration, and this plugin's hooks stopped firing. If you
> installed via `itoh-shun/claude-context-checker` before, remove that marketplace and
> re-add it with one of the two commands above.
>
> Upgrading again: the shared `sito-plugins` marketplace used to live in `itoh-shun/rig`
> (which also hosts the `rig` plugin itself). It moved to a dedicated
> `itoh-shun/sito-plugins` repo that holds only the marketplace manifest — some clients
> (Cowork) failed to list a plugin whose source was the same repo as the marketplace
> that listed it, alongside a sibling plugin that wasn't. If you added
> `itoh-shun/rig` for this marketplace, remove it and re-add `itoh-shun/sito-plugins`
> instead; the install command (`claude-context-checker@sito-plugins`) is unchanged.

That wires the three hooks, the skill, and the subagent status line.

### 2. Add the main status line (required, manual)

**Claude Code plugins cannot install the main status line** — plugin settings support
only the `subagentStatusLine` key, which is why the agent rows are declared for you and
the main bar is not. Without it the hooks have no usage figure to act on, so add this
to `~/.claude/settings.json` yourself:

```json
{
  "statusLine": {
    "type": "command",
    "command": "sh \"$HOME/.claude/plugins/cache/sito-plugins/claude-context-checker/<version>/hooks/run.sh\" \"$HOME/.claude/plugins/cache/sito-plugins/claude-context-checker/<version>/hooks/statusline.py\""
  }
}
```

Check the path against your install — `/plugin` shows where the plugin landed. It is a
`cache/<marketplace-name>/claude-context-checker/<version>/` path, not the
`marketplaces/<marketplace-name>/` one — that directory holds the marketplace's own repo
(e.g. `rig`'s, when installed via the shared marketplace), not this plugin's files.
See [docs/manual-install.md](docs/manual-install.md) to install without the plugin system.

`run.sh` picks a working interpreter instead of assuming `python3`. On Linux and
macOS you can call `python3` directly if you prefer; on Windows you should not —
see below.

### Windows

Windows works, with one catch that is easy to miss. `python3` there is usually the
Microsoft Store alias: it prints `Python was not found` to stderr, exits 49, and runs
nothing, while the real interpreter is `python`. A hook wired to `python3` fails
silently. Measured on a Windows box with Python 3.12.10 installed:

| Command | Result |
| --- | --- |
| `python3 statusline.py` | `Python was not found`, exit 49 |
| `sh run.sh statusline.py` | renders normally |

So use the `run.sh` form above. It probes `python3`, `python`, then `py`, and
`CONTEXT_CHECKER_PYTHON` overrides the probe with an explicit interpreter path.
Claude Code routes these commands through Git Bash when it is installed, which is
what `sh` needs. Forward and backslash paths both work as long as they are quoted.

If you skip this step, the plugin says so once per session rather than failing quietly.
You can also point `CONTEXT_CHECKER_CONTEXT_WINDOW` at your window size in tokens to
estimate usage from the transcript instead — see [Accuracy](#accuracy).

## Configuration

All optional, read from the environment (`env` in `settings.json` works):

| Variable | Default | Meaning |
| --- | --- | --- |
| `CONTEXT_CHECKER_NOTICE_PCT` | `60`, or 15 below auto-compact | First warning threshold |
| `CONTEXT_CHECKER_WARN_PCT` | `75`, or 5 below auto-compact | Critical warning threshold |
| `CONTEXT_CHECKER_STATE_TTL_DAYS` | `14` | Delete per-session state files older than this |
| `CONTEXT_CHECKER_CONTEXT_WINDOW` | unset | Context window size in tokens, for the transcript fallback |
| `CONTEXT_CHECKER_STATUSLINE_SEGMENTS` | `ctx,model,session,limits,cwd` | Which segments the status line shows, in order |
| `CONTEXT_CHECKER_RATE_LIMIT_MIN_PCT` | `0` | Hide a plan-limit window until it reaches this percentage |

### Following the auto-compact point

Warning at a fixed 75% is useless if auto-compact fires at 70% — the critical warning
arrives after the compaction it exists to pre-empt. So when
`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` is set, the thresholds move with it: notice at
15 points below, critical at 5 points below. Setting either `CONTEXT_CHECKER_*_PCT`
variable explicitly overrides that.

The status line shows the point it is working against:

```
[WARN] ctx 62% → auto 70% | ...
```

Claude Code does not publish its built-in auto-compact threshold to hooks, so with
the variable unset the arrow is omitted and the stock 60/75 defaults apply.

## Files written

```
~/.claude/tmp/context-checker/<session>.json         usage snapshot (pruned by TTL)
~/.claude/tmp/context-checker/<session>.seen.json    which thresholds already warned
~/.claude/checkpoints/context-checker/<session>-<ts>.md   pre-compact checkpoint
~/.claude/checkpoints/context-checker/<session>.latest    pointer to the newest one
```

Checkpoints are never pruned automatically — they contain your work, so deleting
them is your call.

## Accuracy

The status line figure comes from Claude Code itself and is exact.

The transcript fallback is only used when you declare a window size, and here is why.
Claude Code's documented formula for context usage counts input tokens only:
`input_tokens + cache_creation_input_tokens + cache_read_input_tokens`. Those numbers
are in the transcript. The **window they are measured against is not** — it appears
nowhere in the transcript, and it is not derivable from the model id: the same
`claude-sonnet-5` runs with a 200k window on some accounts and 1M on others.

Checked against 53 real sessions that had both a recorded status line figure and a
transcript: with the correct window size the estimate lands within 1 percentage point
in 52 of them (median error 0.30pt). Guessing the window from the model id instead
produced errors above 70 points — a CRITICAL warning at 19% actual usage. So this
plugin does not guess. No declared window, no percentage.

That sample came from a single account whose sessions all ran on a 1M window, so it
validates the token formula rather than any range of window sizes. Which is the point:
the formula is dependable, the denominator is what you have to supply.

## Testing

```
bash tests/smoke.sh
```

73 assertions against mock payloads in a throwaway `HOME`: rendering and segment
selection, threshold crossing and non-repetition, thresholds derived from the
auto-compact point, the transcript fallback with and without a declared window,
sidechain exclusion, subagent row rendering and column budget, checkpoint contents,
state pruning, and malformed stdin. It also runs each command string from
`hooks.json` and `settings.json` through a shell to prove `${CLAUDE_PLUGIN_ROOT}`
expands where it is used.

## Limitations

- The main status line must be installed by hand (a Claude Code constraint, not a
  choice); the subagent one is declared in the plugin's `settings.json`.
- The subagent status line is verified at the script and command-string level, but
  has not been observed rendering in a live agent panel. If Claude Code does not pick
  up the plugin's `settings.json`, the rows fall back to their default rendering —
  nothing breaks, you just don't get the percentages.
- Per-agent percentages need Claude Code v2.1.205 or later. Rows without a resolved
  model keep their default rendering rather than showing a made-up number.
- `PreCompact` reads the transcript, so a checkpoint reflects what was written to
  disk, not in-flight state.
- Hooks cannot invoke skills, so the `context-checkpoint` skill is triggered by the
  warning text rather than called directly.

## License

MIT — see [LICENSE](LICENSE).
