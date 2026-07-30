#!/usr/bin/env python3
"""Shared helpers for the context-checker hooks.

Stdlib only. Every function here is defensive: a hook that raises can disrupt
the host session, so failures degrade to "no data" rather than propagating.
"""
from __future__ import annotations

import json
import os
import time
from pathlib import Path

STATE_DIR = Path.home() / ".claude" / "tmp" / "context-checker"
CHECKPOINT_DIR = Path.home() / ".claude" / "checkpoints" / "context-checker"

# Thresholds are shared by statusline.py (colour marker) and prompt-submit.py
# (injected warning) so the two never disagree about what "WARN" means.
DEFAULT_NOTICE_PCT = 60.0
DEFAULT_WARN_PCT = 75.0
DEFAULT_STATE_TTL_DAYS = 14

# When auto-compact is set to fire early, warning at a fixed 60/75 can put the
# critical warning *after* the compaction it exists to pre-empt. So the defaults
# follow the auto-compact point instead, landing this far ahead of it.
NOTICE_LEAD_PCT = 15.0
WARN_LEAD_PCT = 5.0
AUTOCOMPACT_ENV = "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"

# There is deliberately no default context window size. The transcript records
# token counts but never the window they are measured against, and the window
# is not derivable from the model id — `claude-sonnet-5` runs with a 200k window
# for some accounts and 1M for others. Guessing produced errors of 70+ points
# against real sessions (a CRITICAL warning at 19% actual usage), so the
# transcript estimate is only used when the size is stated explicitly.
CONTEXT_WINDOW_ENV = "CONTEXT_CHECKER_CONTEXT_WINDOW"


def _env_float_opt(name: str) -> float | None:
    try:
        return float(os.environ[name])
    except (KeyError, TypeError, ValueError):
        return None


def _env_float(name: str, default: float) -> float:
    value = _env_float_opt(name)
    return default if value is None else value


def autocompact_pct() -> float | None:
    """The usage percentage at which Claude Code will auto-compact, if declared.

    Only the override is knowable from here: Claude Code does not publish its
    built-in threshold to hooks, so an unset variable means "unknown", not "off".
    """
    value = _env_float_opt(AUTOCOMPACT_ENV)
    if value is None or not 0 < value <= 100:
        return None
    return value


def _threshold(explicit_env: str, lead: float, fallback: float) -> float:
    explicit = _env_float_opt(explicit_env)
    if explicit is not None:
        return explicit
    auto = autocompact_pct()
    if auto is not None:
        return max(0.0, auto - lead)
    return fallback


def notice_threshold() -> float:
    return _threshold("CONTEXT_CHECKER_NOTICE_PCT", NOTICE_LEAD_PCT, DEFAULT_NOTICE_PCT)


def warn_threshold() -> float:
    return _threshold("CONTEXT_CHECKER_WARN_PCT", WARN_LEAD_PCT, DEFAULT_WARN_PCT)


def state_ttl_days() -> float:
    return _env_float("CONTEXT_CHECKER_STATE_TTL_DAYS", DEFAULT_STATE_TTL_DAYS)


def level_for(used_pct: float) -> str:
    """Map a usage percentage onto ok / notice / warn."""
    if used_pct >= warn_threshold():
        return "warn"
    if used_pct >= notice_threshold():
        return "notice"
    return "ok"


LEVEL_ORDER = {"ok": 0, "notice": 1, "warn": 2}

# Shared by both status lines so a subagent row and the main bar mean the same
# thing by "WARN".
MARKERS = {"ok": "OK", "notice": "WARN", "warn": "CRIT"}


def marker_for(used_pct: float) -> str:
    return MARKERS[level_for(used_pct)]


def format_pct(value: float) -> str:
    """Render a percentage without a pointless trailing .0."""
    return f"{value:g}"


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def write_json(path: Path, data: dict) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    except Exception:
        pass


def state_path(session_id: str) -> Path:
    return STATE_DIR / f"{session_id}.json"


def seen_path(session_id: str) -> Path:
    return STATE_DIR / f"{session_id}.seen.json"


def prune_state(ttl_days: float | None = None) -> None:
    """Delete state files untouched for longer than the TTL.

    Without this the state directory grows by two files per session forever.
    """
    ttl = state_ttl_days() if ttl_days is None else ttl_days
    if ttl <= 0:
        return
    cutoff = time.time() - ttl * 86400
    try:
        entries = list(STATE_DIR.glob("*.json"))
    except Exception:
        return
    for f in entries:
        try:
            if f.stat().st_mtime < cutoff:
                f.unlink()
        except Exception:
            continue


def configured_context_window() -> int | None:
    """Context window size stated explicitly by the user, if any."""
    try:
        size = int(os.environ[CONTEXT_WINDOW_ENV])
    except (KeyError, TypeError, ValueError):
        return None
    return size if size > 0 else None


def input_tokens_from_transcript(transcript_path: str) -> int | None:
    """Sum the input tokens of the transcript's last main-chain API call.

    Mirrors the documented `used_percentage` formula, which counts input tokens
    only: input + cache_creation + cache_read. Sidechain entries are skipped
    because subagents carry their own context, not the main session's.
    """
    if not transcript_path:
        return None
    path = Path(transcript_path)
    if not path.exists():
        return None

    last_usage = None
    try:
        with path.open(encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except Exception:
                    continue
                if ev.get("isSidechain"):
                    continue
                usage = (ev.get("message") or {}).get("usage")
                if isinstance(usage, dict):
                    last_usage = usage
    except Exception:
        return None

    if not last_usage:
        return None

    total = 0
    for key in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"):
        value = last_usage.get(key)
        if isinstance(value, (int, float)):
            total += value
    return total if total > 0 else None


def resolve_used_pct(payload: dict) -> tuple[float | None, str]:
    """Return (used_pct, source) for a non-statusline hook payload.

    Sources, in order:
      "statusline" — the figure the host itself reported, written by statusline.py
      "transcript" — token sum from the transcript, only when the window size is
                     configured via CONTEXT_CHECKER_CONTEXT_WINDOW
      "unavailable" — neither is available; the caller should say so once
    """
    session_id = payload.get("session_id") or "unknown"
    state = read_json(state_path(session_id))
    used = state.get("used_pct")
    if isinstance(used, (int, float)):
        return float(used), "statusline"

    window = configured_context_window() or state.get("context_window_size")
    tokens = input_tokens_from_transcript(payload.get("transcript_path") or "")
    if isinstance(window, int) and window > 0 and tokens:
        return round(min(100.0, tokens / window * 100), 1), "transcript"

    return None, "unavailable"
