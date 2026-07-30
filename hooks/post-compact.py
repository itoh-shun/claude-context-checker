#!/usr/bin/env python3
"""PostCompact hook: point Claude at the checkpoint written before compaction.

Also resets the threshold-crossing state, so the next crossing after a compact
warns again instead of being suppressed by the pre-compact level.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import (  # noqa: E402
    CHECKPOINT_DIR,
    read_json,
    seen_path,
    write_json,
)


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return

    session_id = payload.get("session_id") or "unknown"

    seen = read_json(seen_path(session_id))
    seen["last_level"] = "ok"
    write_json(seen_path(session_id), seen)

    pointer = CHECKPOINT_DIR / f"{session_id}.latest"
    if not pointer.exists():
        return
    try:
        latest = pointer.read_text(encoding="utf-8").strip()
    except Exception:
        return
    if not latest or not Path(latest).exists():
        return

    print(
        "[context-checker] Compaction completed. A checkpoint of the pre-compact "
        f"state is available at: {latest}\n"
        "If important context appears to be missing from the summary, read that "
        "file to recover prior user messages, files touched, and recent commands."
    )


if __name__ == "__main__":
    main()
