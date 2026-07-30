#!/usr/bin/env python3
"""UserPromptSubmit hook: warn once per upward threshold crossing.

Stdout from this event is injected as context Claude can act on, so the message
is written for Claude rather than for the terminal. State is persisted per
session so a single crossing does not re-warn on every subsequent prompt.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import (  # noqa: E402
    LEVEL_ORDER,
    level_for,
    notice_threshold,
    read_json,
    resolve_used_pct,
    seen_path,
    warn_threshold,
    write_json,
)


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return

    session_id = payload.get("session_id") or "unknown"
    used, source = resolve_used_pct(payload)
    seen = read_json(seen_path(session_id))

    if used is None:
        # Fail loudly once rather than staying silent forever: without the status
        # line there is no usage figure, and a misconfigured install would
        # otherwise look identical to a healthy one.
        if not seen.get("setup_notified"):
            seen["setup_notified"] = True
            write_json(seen_path(session_id), seen)
            print(
                "[context-checker] Context warnings are inactive: no usage figure is "
                "available for this session. The status line component records it, and "
                "plugins cannot install a status line automatically. Add it to "
                "settings.json as described in the context-checker README, or set "
                "CONTEXT_CHECKER_CONTEXT_WINDOW to your context window size in tokens "
                "to estimate usage from the transcript instead. Mention this to the "
                "user once, then carry on with their request."
            )
        return

    level = level_for(used)
    last = seen.get("last_level", "ok")
    seen["last_level"] = level
    write_json(seen_path(session_id), seen)

    if LEVEL_ORDER[level] <= LEVEL_ORDER.get(last, 0):
        return

    qualifier = " (estimated from transcript)" if source == "transcript" else ""

    if level == "warn":
        print(
            f"[context-checker] CRITICAL: context usage {used}%{qualifier} "
            f"(>= {warn_threshold()}%). Auto-compact is close. Use the "
            "`context-checkpoint` skill to write a checkpoint now, then consider "
            "running `/compact <instructions>` manually so you control what survives."
        )
    elif level == "notice":
        print(
            f"[context-checker] NOTICE: context usage {used}%{qualifier} "
            f"(>= {notice_threshold()}%). Start wrapping up the current sub-task; "
            "the `context-checkpoint` skill can prepare a `/compact` instruction string."
        )


if __name__ == "__main__":
    main()
