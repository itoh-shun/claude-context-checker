#!/usr/bin/env python3
"""statusLine command: render session state and record context usage.

Two jobs:
  1. Print one line for the Claude Code status bar.
  2. Persist the host-reported usage figure, which is the only place the other
     hooks can read an authoritative percentage from.

Which segments appear is controlled by CONTEXT_CHECKER_STATUSLINE_SEGMENTS, a
comma-separated subset of: ctx, model, session, limits, cwd.
"""
import json
import os
import sys
from datetime import datetime
from pathlib import Path

# Keep the plugin install directory free of __pycache__ noise.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import (  # noqa: E402
    read_payload,
    autocompact_pct,
    format_pct,
    marker_for,
    prune_state,
    state_path,
    write_json,
)

DEFAULT_SEGMENTS = "ctx,model,session,limits,cwd"
RATE_LIMIT_MIN_ENV = "CONTEXT_CHECKER_RATE_LIMIT_MIN_PCT"


def enabled_segments() -> list[str]:
    raw = os.environ.get("CONTEXT_CHECKER_STATUSLINE_SEGMENTS") or DEFAULT_SEGMENTS
    return [s.strip() for s in raw.split(",") if s.strip()]


def used_percentage(ctx: dict) -> float | None:
    value = ctx.get("used_percentage")
    if isinstance(value, (int, float)):
        return float(value)
    remaining = ctx.get("remaining_percentage")
    if isinstance(remaining, (int, float)):
        return round(100 - remaining, 1)
    return None


def ctx_segment(used_pct: float | None) -> str:
    if used_pct is None:
        body = "ctx ?%"
    else:
        body = f"[{marker_for(used_pct)}] ctx {format_pct(used_pct)}%"
    auto = autocompact_pct()
    return f"{body} → auto {format_pct(auto)}%" if auto is not None else body


def session_segment(payload: dict) -> str:
    """Effort level plus whichever session modes are on."""
    parts = []
    level = (payload.get("effort") or {}).get("level")
    if isinstance(level, str) and level:
        parts.append(level)
    if (payload.get("thinking") or {}).get("enabled"):
        parts.append("think")
    if payload.get("fast_mode"):
        parts.append("fast")
    return "·".join(parts)


def limits_segment(payload: dict) -> str:
    """Plan usage windows, hidden below the configured floor.

    Absent entirely for API-key auth, and for subscribers until the first API
    response of the session — so this segment is often empty by design.
    """
    limits = payload.get("rate_limits") or {}
    try:
        floor = float(os.environ.get(RATE_LIMIT_MIN_ENV, "0"))
    except (TypeError, ValueError):
        floor = 0.0

    parts = []
    for key, label in (("five_hour", "5h"), ("seven_day", "7d")):
        pct = (limits.get(key) or {}).get("used_percentage")
        if isinstance(pct, (int, float)) and pct >= floor:
            parts.append(f"{label} {format_pct(float(pct))}%")
    return " · ".join(parts)


def main() -> None:
    payload = read_payload()
    if payload is None:
        print("")
        return

    session_id = payload.get("session_id") or "unknown"
    ctx = payload.get("context_window") or {}
    model = payload.get("model") or {}
    workspace = payload.get("workspace") or {}

    used_pct = used_percentage(ctx)
    model_id = model.get("id") or ""
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
            "autocompact_pct": autocompact_pct(),
            "model": model_id,
            "cwd": cwd,
        },
    )
    prune_state()

    available = {
        "ctx": ctx_segment(used_pct),
        "model": model.get("display_name") or model_id,
        "session": session_segment(payload),
        "limits": limits_segment(payload),
        "cwd": Path(cwd).name if cwd else "",
    }
    rendered = [available.get(name, "") for name in enabled_segments()]
    print(" | ".join(part for part in rendered if part))


if __name__ == "__main__":
    main()
