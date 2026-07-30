#!/usr/bin/env python3
"""statusLine command: render context usage and record it for the hooks.

Two jobs:
  1. Print one line for the Claude Code status bar.
  2. Persist the host-reported usage figure, which is the only place the other
     hooks can read an authoritative percentage from.
"""
import json
import sys
from datetime import datetime
from pathlib import Path

# Keep the plugin install directory free of __pycache__ noise.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import (  # noqa: E402
    level_for,
    prune_state,
    state_path,
    write_json,
)

MARKERS = {"ok": "OK", "notice": "WARN", "warn": "CRIT"}


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        print("")
        return

    session_id = payload.get("session_id") or "unknown"
    ctx = payload.get("context_window") or {}
    model = payload.get("model") or {}
    workspace = payload.get("workspace") or {}

    used_pct = ctx.get("used_percentage")
    if not isinstance(used_pct, (int, float)):
        remaining = ctx.get("remaining_percentage")
        used_pct = round(100 - remaining, 1) if isinstance(remaining, (int, float)) else None

    model_id = model.get("id") or ""
    display_name = model.get("display_name") or model_id
    cwd = workspace.get("current_dir") or payload.get("cwd") or ""

    write_json(
        state_path(session_id),
        {
            "session_id": session_id,
            "updated_at": datetime.now().isoformat(timespec="seconds"),
            "used_pct": used_pct,
            "remaining_pct": ctx.get("remaining_percentage"),
            "total_input_tokens": ctx.get("total_input_tokens"),
            "context_window_size": ctx.get("context_window_size"),
            "model": model_id,
            "cwd": cwd,
        },
    )
    prune_state()

    cwd_name = Path(cwd).name if cwd else ""
    if used_pct is None:
        bar = "ctx ?%"
    else:
        bar = f"[{MARKERS[level_for(used_pct)]}] ctx {used_pct}%"

    print(" | ".join(part for part in (bar, display_name, cwd_name) if part))


if __name__ == "__main__":
    main()
