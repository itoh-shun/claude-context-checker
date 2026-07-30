#!/usr/bin/env python3
"""subagentStatusLine command: show each subagent's context usage as a percentage.

The default row renders a raw token count, which does not say how close that
agent is to its own limit — 48k is comfortable on a 1M window and nearly half
of a 200k one. Claude Code supplies both `tokenCount` and `contextWindowSize`
per task, so this renders the ratio using the same OK/WARN/CRIT thresholds as
the main status line.

Input is a single JSON object with `columns` and a `tasks` array. Output is one
JSON line per row to override; a row we cannot improve on is left alone by
simply not emitting it.
"""
import json
import sys
from pathlib import Path

# Keep the plugin install directory free of __pycache__ noise.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import format_pct, marker_for  # noqa: E402

MIN_COLUMNS = 24
SEPARATOR = " · "


def used_pct(task: dict) -> float | None:
    """Percentage of that subagent's own context window in use.

    Both fields need Claude Code v2.1.205+ and are omitted while a task's model
    is still unresolved, so absence is normal rather than an error.
    """
    tokens = task.get("tokenCount")
    window = task.get("contextWindowSize")
    if not isinstance(tokens, (int, float)) or not isinstance(window, (int, float)):
        return None
    if window <= 0 or tokens < 0:
        return None
    return round(min(100.0, tokens / window * 100), 1)


def render(task: dict, pct: float, columns: int) -> str:
    head = f"[{marker_for(pct)}] "
    tail = f"{SEPARATOR}{format_pct(pct)}%"
    name = str(task.get("name") or task.get("type") or "agent")
    detail = str(task.get("label") or task.get("description") or "")

    line = f"{head}{name}{SEPARATOR}{detail}{tail}" if detail else f"{head}{name}{tail}"
    if columns <= 0 or len(line) <= columns:
        return line

    # Trim the description rather than the marker or the percentage: those are
    # the two things this row exists to add.
    budget = columns - len(head) - len(name) - len(tail) - len(SEPARATOR)
    if budget < 4:
        return f"{head}{name}{tail}"[:columns] if columns >= MIN_COLUMNS else line[:columns]
    return f"{head}{name}{SEPARATOR}{detail[:budget - 1]}…{tail}"


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return

    tasks = payload.get("tasks")
    if not isinstance(tasks, list):
        return
    columns = payload.get("columns")
    columns = columns if isinstance(columns, int) and columns > 0 else 0

    for task in tasks:
        if not isinstance(task, dict):
            continue
        task_id = task.get("id")
        if not task_id:
            continue
        pct = used_pct(task)
        if pct is None:
            continue  # leave the default rendering in place
        print(json.dumps({"id": task_id, "content": render(task, pct, columns)},
                         ensure_ascii=False))


if __name__ == "__main__":
    main()
