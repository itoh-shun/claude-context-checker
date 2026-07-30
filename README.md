# context-checker

Watch the context window, and survive compaction.

A Claude Code plugin that shows how full the context window is, warns once when it
gets tight, and writes a checkpoint of what you were doing right before the
transcript is summarized away — so a compaction never silently drops the thread.

日本語版は [README.ja.md](README.ja.md)。

## What it does

| Component | Event | Behaviour |
| --- | --- | --- |
| `statusline.py` | status line | Renders `[OK] ctx 24% \| Opus 5 \| my-project` and records the usage figure for the hooks to read |
| `prompt-submit.py` | `UserPromptSubmit` | Injects one warning when usage crosses 60%, one more when it crosses 75%. Never repeats within the same level |
| `pre-compact.py` | `PreCompact` | Writes a markdown checkpoint: recent user messages verbatim, truncated assistant replies, files edited, commands run |
| `post-compact.py` | `PostCompact` | Tells Claude where that checkpoint is, so anything the summary dropped can be recovered |
| `context-checkpoint` | skill | Prepares a structured checkpoint and drafts a `/compact <instructions>` string. You decide whether to run it |

Python 3 standard library only. No dependencies, no network calls.

## Install

### 1. Add the plugin

```
/plugin marketplace add <your-github-user>/context-checker
/plugin install context-checker@context-checker
```

That wires the three hooks and the skill.

### 2. Add the status line (required, manual)

**Claude Code plugins cannot install a status line** — only the `subagentStatusLine`
key is supported in plugin settings, not the main one. Without it the hooks have no
usage figure to act on, so add this to `~/.claude/settings.json` yourself:

```json
{
  "statusLine": {
    "type": "command",
    "command": "python3 \"$HOME/.claude/plugins/marketplaces/context-checker/hooks/statusline.py\""
  }
}
```

Check the path against your install — `/plugin` shows where the plugin landed.
See [docs/manual-install.md](docs/manual-install.md) to install without the plugin system.

If you skip this step, the plugin says so once per session rather than failing quietly.
You can also point `CONTEXT_CHECKER_CONTEXT_WINDOW` at your window size in tokens to
estimate usage from the transcript instead — see [Accuracy](#accuracy).

## Configuration

All optional, read from the environment (`env` in `settings.json` works):

| Variable | Default | Meaning |
| --- | --- | --- |
| `CONTEXT_CHECKER_NOTICE_PCT` | `60` | First warning threshold |
| `CONTEXT_CHECKER_WARN_PCT` | `75` | Critical warning threshold |
| `CONTEXT_CHECKER_STATE_TTL_DAYS` | `14` | Delete per-session state files older than this |
| `CONTEXT_CHECKER_CONTEXT_WINDOW` | unset | Context window size in tokens, for the transcript fallback |

If you set `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`, auto-compact fires earlier than the
default. Set `CONTEXT_CHECKER_WARN_PCT` below it, or the critical warning arrives
after the compaction it was meant to prevent.

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

Runs every hook against mock payloads in a throwaway `HOME`: rendering, threshold
crossing and non-repetition, the transcript fallback with and without a declared
window, sidechain exclusion, checkpoint contents, state pruning, and malformed stdin.

## Limitations

- The status line must be installed by hand (a Claude Code constraint, not a choice).
- `PreCompact` reads the transcript, so a checkpoint reflects what was written to
  disk, not in-flight state.
- Hooks cannot invoke skills, so the `context-checkpoint` skill is triggered by the
  warning text rather than called directly.

## License

MIT — see [LICENSE](LICENSE).
