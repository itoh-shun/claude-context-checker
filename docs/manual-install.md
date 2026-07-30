# Manual install (without the plugin system)

Use this if you would rather clone the repo and wire it into `settings.json`
yourself, or if you want to run it from a checkout while making changes.

## 1. Clone

```bash
git clone https://github.com/<your-github-user>/context-checker.git ~/.claude/context-checker
```

Any path works; the scripts locate their own directory. The examples below assume
`~/.claude/context-checker`.

## 2. Wire the status line and hooks

Merge into `~/.claude/settings.json`. `$HOME` is not expanded inside hook commands
on every platform, so absolute paths are the safe choice.

```json
{
  "statusLine": {
    "type": "command",
    "command": "python3 /home/YOU/.claude/context-checker/hooks/statusline.py"
  },
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "python3 /home/YOU/.claude/context-checker/hooks/prompt-submit.py"
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "python3 /home/YOU/.claude/context-checker/hooks/pre-compact.py"
          }
        ]
      }
    ],
    "PostCompact": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "python3 /home/YOU/.claude/context-checker/hooks/post-compact.py"
          }
        ]
      }
    ]
  }
}
```

If `settings.json` already has a `hooks` object, merge the event arrays rather than
replacing them — an existing `UserPromptSubmit` entry and this one can coexist.

## 3. Install the skill

```bash
mkdir -p ~/.claude/skills
ln -s ~/.claude/context-checker/skills/context-checkpoint ~/.claude/skills/context-checkpoint
```

## 4. Verify

Restart Claude Code. The status line should show `ctx <n>%`. Then check the hooks
actually fire:

```bash
ls ~/.claude/tmp/context-checker/          # appears after the status line runs once
```

Send a prompt, then run `/compact` and confirm a checkpoint lands:

```bash
ls ~/.claude/checkpoints/context-checker/
```

`claude --debug` prints hook execution, including non-zero exits and stderr.

## Uninstall

Remove the `statusLine` and `hooks` entries from `settings.json`, delete the symlink,
and remove the clone. State and checkpoints live under `~/.claude/tmp/context-checker`
and `~/.claude/checkpoints/context-checker`; delete them if you no longer want them.
