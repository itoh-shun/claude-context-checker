#!/usr/bin/env python3
"""PreCompact hook: save a checkpoint of recent work before context is summarized.

Reads the transcript and writes a markdown checkpoint containing:
- session id, cwd, trigger, timestamp
- last N user messages (verbatim)
- last K assistant messages (truncated)
- files touched via Edit/Write/MultiEdit/NotebookEdit
- recent bash commands
"""
import json
import sys
from datetime import datetime
from pathlib import Path

# Keep the plugin install directory free of __pycache__ noise.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import CHECKPOINT_DIR, read_payload  # noqa: E402

LAST_USER = 6
LAST_ASSISTANT = 4
LAST_BASH = 20
LAST_FILES = 30
ASSISTANT_TRUNC = 1200
USER_TRUNC = 2000

EDIT_TOOLS = ("Edit", "Write", "MultiEdit", "NotebookEdit")


def iter_transcript(path: Path):
    if not path.exists():
        return
    try:
        with path.open(encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    yield json.loads(line)
                except Exception:
                    continue
    except Exception:
        return


def text_of(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = [
            c.get("text", "")
            for c in content
            if isinstance(c, dict) and c.get("type") == "text"
        ]
        return "\n".join(parts)
    return ""


def collect(transcript_path: str) -> dict:
    user_msgs: list[str] = []
    assistant_msgs: list[str] = []
    files_touched: list[str] = []
    bash_log: list[str] = []
    cwd = ""

    for ev in iter_transcript(Path(transcript_path)) if transcript_path else []:
        msg = ev.get("message") or {}
        role = msg.get("role")
        cwd = ev.get("cwd") or cwd

        if role == "user":
            txt = text_of(msg.get("content"))
            # Skip tool results and system-reminder envelopes, which start with '<'.
            if txt and not txt.lstrip().startswith("<"):
                user_msgs.append(txt)
        elif role == "assistant":
            content = msg.get("content")
            if not isinstance(content, list):
                continue
            for c in content:
                if not isinstance(c, dict):
                    continue
                kind = c.get("type")
                if kind == "text":
                    txt = c.get("text", "")
                    if txt:
                        assistant_msgs.append(txt)
                elif kind == "tool_use":
                    name = c.get("name", "")
                    inp = c.get("input") or {}
                    if name in EDIT_TOOLS:
                        fp = inp.get("file_path") or inp.get("notebook_path")
                        if fp:
                            files_touched.append(f"{name}: {fp}")
                    elif name == "Bash":
                        desc = inp.get("description") or ""
                        raw = (inp.get("command") or "").splitlines()
                        cmd = raw[0][:120] if raw else ""
                        bash_log.append(f"{desc}  -- {cmd}" if desc else cmd)

    return {
        "user_msgs": user_msgs,
        "assistant_msgs": assistant_msgs,
        "files_touched": files_touched,
        "bash_log": bash_log,
        "cwd": cwd,
    }


def render(data: dict, session_id: str, trigger: str, custom: str,
           transcript_path: str, ts: str) -> str:
    lines = [
        f"# Context Checkpoint — {ts}",
        "",
        f"- session_id: `{session_id}`",
        f"- trigger: `{trigger}`",
        f"- cwd: `{data['cwd']}`",
        f"- transcript: `{transcript_path}`",
    ]
    if custom:
        lines += ["", "## /compact instructions provided", "", "```", custom, "```"]

    lines += ["", f"## Last {LAST_USER} user messages", ""]
    for m in data["user_msgs"][-LAST_USER:]:
        lines += ["```", m.strip()[:USER_TRUNC], "```", ""]

    lines += [f"## Last {LAST_ASSISTANT} assistant messages (truncated)", ""]
    for m in data["assistant_msgs"][-LAST_ASSISTANT:]:
        snippet = m.strip()
        if len(snippet) > ASSISTANT_TRUNC:
            snippet = snippet[:ASSISTANT_TRUNC] + " …(truncated)"
        lines += ["```", snippet, "```", ""]

    if data["files_touched"]:
        lines += ["## Files touched (recent)", ""]
        lines += [f"- {f}" for f in data["files_touched"][-LAST_FILES:]]
        lines.append("")

    if data["bash_log"]:
        lines += [f"## Last {LAST_BASH} bash commands", ""]
        lines += [f"- {b}" for b in data["bash_log"][-LAST_BASH:]]
        lines.append("")

    return "\n".join(lines)


def main() -> None:
    payload = read_payload()
    if payload is None:
        return

    session_id = payload.get("session_id") or "unknown"
    trigger = payload.get("trigger") or "unknown"
    custom = payload.get("custom_instructions") or ""
    transcript_path = payload.get("transcript_path") or ""

    data = collect(transcript_path)
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    body = render(data, session_id, trigger, custom, transcript_path, ts)

    out = CHECKPOINT_DIR / f"{session_id}-{ts}.md"
    try:
        CHECKPOINT_DIR.mkdir(parents=True, exist_ok=True)
        out.write_text(body, encoding="utf-8")
    except Exception as e:
        print(f"[context-checker] checkpoint write failed: {e}", file=sys.stderr)
        return

    try:
        (CHECKPOINT_DIR / f"{session_id}.latest").write_text(str(out), encoding="utf-8")
    except Exception:
        pass


if __name__ == "__main__":
    main()
