#!/bin/sh
# Run one of the hook scripts under whichever Python is actually present.
#
# `python3` is not a safe assumption. On Windows it usually resolves to the
# Microsoft Store alias, which prints "Python was not found" to stderr and exits
# 49 without running anything, while the real interpreter is `python`. On many
# Linux distributions the reverse holds and only `python3` exists.
#
# The interpreter has to be chosen *before* the hook reads stdin: Claude Code
# pipes the payload in once, so a "try python3, fall back to python" chain would
# hand the second attempt an empty stream. Hence this launcher — probe first,
# then exec, so the payload is read exactly once by an interpreter known to work.
#
# Usage: sh run.sh <absolute path to hook script>
# Override the probe with CONTEXT_CHECKER_PYTHON=/path/to/python.

set -u

SCRIPT="${1:-}"
if [ -z "$SCRIPT" ]; then
    echo "run.sh: no hook script given" >&2
    exit 2
fi
shift

if [ -n "${CONTEXT_CHECKER_PYTHON:-}" ]; then
    exec "$CONTEXT_CHECKER_PYTHON" "$SCRIPT" "$@"
fi

for candidate in python3 python py; do
    if "$candidate" -c "" >/dev/null 2>&1; then
        exec "$candidate" "$SCRIPT" "$@"
    fi
done

echo "run.sh: no working Python found (tried python3, python, py). Set CONTEXT_CHECKER_PYTHON to an interpreter path." >&2
exit 127
