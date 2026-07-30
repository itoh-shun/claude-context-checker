#!/bin/bash
# Smoke test for context-checker hooks against mock payloads.
set -u
PLUGIN=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SANDBOX=$(mktemp -d)
export HOME="$SANDBOX"
# The suite asserts on exact thresholds, so it must not inherit the tester's own
# configuration — CLAUDE_AUTOCOMPACT_PCT_OVERRIDE in particular moves every default.
unset CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
unset CONTEXT_CHECKER_NOTICE_PCT CONTEXT_CHECKER_WARN_PCT
unset CONTEXT_CHECKER_CONTEXT_WINDOW CONTEXT_CHECKER_STATE_TTL_DAYS
unset CONTEXT_CHECKER_STATUSLINE_SEGMENTS CONTEXT_CHECKER_RATE_LIMIT_MIN_PCT
mkdir -p "$HOME/.claude"
SID="test-session-1"
TRANSCRIPT="$SANDBOX/transcript.jsonl"
fail=0

ok()   { echo "  PASS: $1"; }
bad()  { echo "  FAIL: $1"; fail=1; }

# --- build a mock transcript -------------------------------------------------
cat > "$TRANSCRIPT" <<'EOF'
{"cwd":"/home/u/proj","message":{"role":"user","content":"最初の依頼です"}}
{"cwd":"/home/u/proj","message":{"role":"assistant","content":[{"type":"text","text":"了解しました"},{"type":"tool_use","name":"Write","input":{"file_path":"/home/u/proj/a.py"}},{"type":"tool_use","name":"Bash","input":{"description":"run tests","command":"pytest -q\nmore"}}],"usage":{"input_tokens":10,"cache_creation_input_tokens":5000,"cache_read_input_tokens":155000,"output_tokens":300},"model":"claude-opus-5"}}
{"cwd":"/home/u/proj","message":{"role":"user","content":"<tool_result>ignored envelope</tool_result>"}}
{"cwd":"/home/u/proj","message":{"role":"user","content":"2つ目の依頼です"}}
EOF

echo "== 1. statusline: renders and records state =="
OUT=$(echo "{\"session_id\":\"$SID\",\"context_window\":{\"used_percentage\":62.5,\"remaining_percentage\":37.5,\"context_window_size\":200000,\"total_input_tokens\":125000},\"model\":{\"id\":\"claude-opus-5\",\"display_name\":\"Opus 5\"},\"workspace\":{\"current_dir\":\"/home/u/proj\"}}" | python3 "$PLUGIN/hooks/statusline.py")
echo "  output: $OUT"
[[ "$OUT" == "[WARN] ctx 62.5% | Opus 5 | proj" ]] && ok "statusline output" || bad "statusline output"
STATE="$HOME/.claude/tmp/context-checker/$SID.json"
[[ -f "$STATE" ]] && ok "state file written" || bad "state file written"
python3 -c "
import json,sys
d=json.load(open('$STATE'))
assert d['used_pct']==62.5, d
assert d['context_window_size']==200000, d
assert d['total_input_tokens']==125000, d
" && ok "state contents" || bad "state contents"

echo "== 2. statusline: null percentages degrade gracefully =="
OUT=$(echo "{\"session_id\":\"null-sess\",\"context_window\":{\"used_percentage\":null,\"remaining_percentage\":null},\"model\":{\"id\":\"claude-fable-5\",\"display_name\":\"Fable 5\"},\"workspace\":{\"current_dir\":\"/home/u/proj\"}}" | python3 "$PLUGIN/hooks/statusline.py")
echo "  output: $OUT"
[[ "$OUT" == "ctx ?% | Fable 5 | proj" ]] && ok "null handling" || bad "null handling"

echo "== 3. prompt-submit: warns once on upward crossing (statusline source) =="
P="{\"session_id\":\"$SID\",\"transcript_path\":\"$TRANSCRIPT\"}"
OUT1=$(echo "$P" | python3 "$PLUGIN/hooks/prompt-submit.py")
OUT2=$(echo "$P" | python3 "$PLUGIN/hooks/prompt-submit.py")
echo "  1st: $OUT1"
echo "  2nd: [$OUT2]"
[[ "$OUT1" == *"NOTICE"* && "$OUT1" == *"62.5%"* ]] && ok "notice emitted" || bad "notice emitted"
[[ "$OUT1" != *"estimated from transcript"* ]] && ok "used statusline source" || bad "used statusline source"
[[ -z "$OUT2" ]] && ok "no repeat within same level" || bad "no repeat within same level"

echo "== 4. prompt-submit: escalates to CRITICAL =="
echo "{\"session_id\":\"$SID\",\"context_window\":{\"used_percentage\":80},\"model\":{\"id\":\"claude-opus-5\",\"display_name\":\"Opus 5\"},\"workspace\":{\"current_dir\":\"/home/u/proj\"}}" | python3 "$PLUGIN/hooks/statusline.py" >/dev/null
OUT=$(echo "$P" | python3 "$PLUGIN/hooks/prompt-submit.py")
echo "  output: $OUT"
[[ "$OUT" == *"CRITICAL"* && "$OUT" == *"80"* ]] && ok "escalation" || bad "escalation"

echo "== 5. prompt-submit: NO transcript guess without a declared window =="
SID2="no-statusline"
P2="{\"session_id\":\"$SID2\",\"transcript_path\":\"$TRANSCRIPT\"}"
OUT=$(echo "$P2" | python3 "$PLUGIN/hooks/prompt-submit.py")
echo "  1st: ${OUT:0:70}..."
[[ "$OUT" == *"Context warnings are inactive"* ]] && ok "setup notice emitted once" || bad "setup notice emitted once"
[[ "$OUT" != *"%"*"CRITICAL"* ]] && ok "no invented percentage" || bad "no invented percentage"
OUT2=$(echo "$P2" | python3 "$PLUGIN/hooks/prompt-submit.py")
[[ -z "$OUT2" ]] && ok "setup notice not repeated" || bad "setup notice not repeated"

echo "== 6. prompt-submit: transcript estimate ONLY with declared window =="
# 10 + 5000 + 155000 = 160010 input tokens; 160010 / 200000 = 80.0%
OUT=$(CONTEXT_CHECKER_CONTEXT_WINDOW=200000 bash -c "echo '{\"session_id\":\"declared\",\"transcript_path\":\"$TRANSCRIPT\"}' | python3 '$PLUGIN/hooks/prompt-submit.py'")
echo "  output: $OUT"
[[ "$OUT" == *"CRITICAL"* && "$OUT" == *"estimated from transcript"* && "$OUT" == *"80%"* ]] \
  && ok "declared-window estimate" || bad "declared-window estimate"
# same transcript, 1M window -> 16.0%, below every threshold -> silence
OUT=$(CONTEXT_CHECKER_CONTEXT_WINDOW=1000000 bash -c "echo '{\"session_id\":\"declared1m\",\"transcript_path\":\"$TRANSCRIPT\"}' | python3 '$PLUGIN/hooks/prompt-submit.py'")
[[ -z "$OUT" ]] && ok "window size respected (1M -> quiet)" || bad "window size respected (1M -> quiet)"

echo "== 7. prompt-submit: threshold override via env =="
echo "{\"session_id\":\"envtest\",\"context_window\":{\"used_percentage\":20},\"model\":{\"id\":\"claude-opus-5\",\"display_name\":\"Opus 5\"},\"workspace\":{\"current_dir\":\"/x\"}}" | python3 "$PLUGIN/hooks/statusline.py" >/dev/null
OUT=$(CONTEXT_CHECKER_NOTICE_PCT=10 CONTEXT_CHECKER_WARN_PCT=90 bash -c "echo '{\"session_id\":\"envtest\",\"transcript_path\":\"$TRANSCRIPT\"}' | python3 '$PLUGIN/hooks/prompt-submit.py'")
echo "  output: $OUT"
[[ "$OUT" == *"NOTICE"* && "$OUT" == *"20%"* && "$OUT" == *">= 10%"* ]] && ok "env thresholds" || bad "env thresholds"

echo "== 7b. sidechain usage records are ignored =="
SIDEC="$SANDBOX/side.jsonl"
cp "$TRANSCRIPT" "$SIDEC"
echo '{"isSidechain":true,"message":{"role":"assistant","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":999999,"output_tokens":1},"model":"claude-opus-5"}}' >> "$SIDEC"
OUT=$(CONTEXT_CHECKER_CONTEXT_WINDOW=200000 bash -c "echo '{\"session_id\":\"sidechain\",\"transcript_path\":\"$SIDEC\"}' | python3 '$PLUGIN/hooks/prompt-submit.py'")
[[ "$OUT" == *"80%"* ]] && ok "sidechain skipped" || bad "sidechain skipped (got: ${OUT:0:60})"

echo "== 8. pre-compact: writes checkpoint + latest pointer =="
echo "{\"session_id\":\"$SID\",\"trigger\":\"auto\",\"custom_instructions\":\"keep the hooks work\",\"transcript_path\":\"$TRANSCRIPT\"}" | python3 "$PLUGIN/hooks/pre-compact.py"
CKDIR="$HOME/.claude/checkpoints/context-checker"
LATEST="$CKDIR/$SID.latest"
[[ -f "$LATEST" ]] && ok "latest pointer" || bad "latest pointer"
CK=$(cat "$LATEST" 2>/dev/null)
[[ -f "$CK" ]] && ok "checkpoint file exists" || bad "checkpoint file exists"
grep -q "最初の依頼です" "$CK" && ok "user message captured" || bad "user message captured"
grep -q "2つ目の依頼です" "$CK" && ok "second user message captured" || bad "second user message captured"
grep -q "ignored envelope" "$CK" && bad "tool_result envelope leaked" || ok "tool_result envelope skipped"
grep -q "Write: /home/u/proj/a.py" "$CK" && ok "files touched captured" || bad "files touched captured"
grep -q "run tests  -- pytest -q" "$CK" && ok "bash captured (first line only)" || bad "bash captured"
grep -q "keep the hooks work" "$CK" && ok "custom instructions captured" || bad "custom instructions captured"

echo "== 9. post-compact: points at checkpoint and resets level =="
OUT=$(echo "{\"session_id\":\"$SID\"}" | python3 "$PLUGIN/hooks/post-compact.py")
echo "  output: ${OUT:0:90}..."
[[ "$OUT" == *"$CK"* ]] && ok "pointer injected" || bad "pointer injected"
python3 -c "
import json
d=json.load(open('$HOME/.claude/tmp/context-checker/$SID.seen.json'))
assert d['last_level']=='ok', d
" && ok "level reset" || bad "level reset"

echo "== 10. all hooks survive malformed stdin =="
for h in statusline prompt-submit pre-compact post-compact; do
  echo "not json" | python3 "$PLUGIN/hooks/$h.py" >/dev/null 2>&1
  [[ $? -eq 0 ]] && ok "$h exit 0 on bad input" || bad "$h exit 0 on bad input"
done

echo "== 11. state pruning removes stale files =="
touch -d "30 days ago" "$HOME/.claude/tmp/context-checker/old-session.json"
echo "{\"session_id\":\"prune-check\",\"context_window\":{\"used_percentage\":5},\"model\":{\"id\":\"claude-opus-5\",\"display_name\":\"Opus 5\"},\"workspace\":{\"current_dir\":\"/x\"}}" | python3 "$PLUGIN/hooks/statusline.py" >/dev/null
[[ ! -f "$HOME/.claude/tmp/context-checker/old-session.json" ]] && ok "stale pruned" || bad "stale pruned"
[[ -f "$HOME/.claude/tmp/context-checker/prune-check.json" ]] && ok "fresh kept" || bad "fresh kept"

echo "== 12. hooks.json / plugin.json / marketplace.json are valid =="
for f in hooks/hooks.json .claude-plugin/plugin.json .claude-plugin/marketplace.json; do
  python3 -c "import json;json.load(open('$PLUGIN/$f'))" 2>/dev/null && ok "$f valid" || bad "$f valid"
done

echo "== 13. every hooks.json command runs as written, with \$CLAUDE_PLUGIN_ROOT expanded =="
# The wiring is only real if the command string survives shell expansion. Run each
# one exactly as Claude Code would, with the variable set, and require exit 0.
mapfile -t CMDS < <(python3 - "$PLUGIN/hooks/hooks.json" <<'PY'
import json, sys
spec = json.load(open(sys.argv[1]))["hooks"]
for event, groups in spec.items():
    for g in groups:
        for h in g.get("hooks", []):
            print(f"{event}\t{h['command']}")
PY
)
[[ ${#CMDS[@]} -eq 3 ]] && ok "3 hook commands declared" || bad "3 hook commands declared (got ${#CMDS[@]})"
for entry in "${CMDS[@]}"; do
  event=${entry%%$'\t'*}
  cmd=${entry#*$'\t'}
  OUT=$(CLAUDE_PLUGIN_ROOT="$PLUGIN" sh -c "echo '{\"session_id\":\"wiring\",\"transcript_path\":\"$TRANSCRIPT\",\"trigger\":\"manual\"}' | $cmd" 2>&1)
  rc=$?
  if [[ $rc -eq 0 && "$OUT" != *"can't open file"* && "$OUT" != *"No such file"* ]]; then
    ok "$event command executes"
  else
    bad "$event command executes (rc=$rc, out=${OUT:0:80})"
  fi
done
# and prove the substitution is load-bearing: without the variable it must fail
UNSET_OUT=$(sh -c "echo '{}' | $(printf '%s' "${CMDS[0]#*$'\t'}")" 2>&1)
[[ "$UNSET_OUT" == *"can't open file"* || "$UNSET_OUT" == *"No such file"* ]] \
  && ok "path really comes from \$CLAUDE_PLUGIN_ROOT" || bad "path really comes from \$CLAUDE_PLUGIN_ROOT"

echo "== 14. statusline segments: session state and rate limits =="
FULL="{\"session_id\":\"seg\",\"context_window\":{\"used_percentage\":24},\"model\":{\"id\":\"claude-opus-5[1m]\",\"display_name\":\"Opus 5 (1M context)\"},\"workspace\":{\"current_dir\":\"/home/u/proj\"},\"effort\":{\"level\":\"high\"},\"thinking\":{\"enabled\":true},\"fast_mode\":false,\"rate_limits\":{\"five_hour\":{\"used_percentage\":27},\"seven_day\":{\"used_percentage\":35}}}"
OUT=$(echo "$FULL" | python3 "$PLUGIN/hooks/statusline.py")
echo "  output: $OUT"
[[ "$OUT" == "[OK] ctx 24% | Opus 5 (1M context) | high·think | 5h 27% · 7d 35% | proj" ]] \
  && ok "all segments" || bad "all segments"

OUT=$(echo "${FULL/\"fast_mode\":false/\"fast_mode\":true}" | python3 "$PLUGIN/hooks/statusline.py")
[[ "$OUT" == *"high·think·fast"* ]] && ok "fast mode shown" || bad "fast mode shown"

OUT=$(CONTEXT_CHECKER_STATUSLINE_SEGMENTS=ctx,cwd bash -c "echo '$FULL' | python3 '$PLUGIN/hooks/statusline.py'")
echo "  ctx,cwd only: $OUT"
[[ "$OUT" == "[OK] ctx 24% | proj" ]] && ok "segment selection" || bad "segment selection"

OUT=$(CONTEXT_CHECKER_RATE_LIMIT_MIN_PCT=30 bash -c "echo '$FULL' | python3 '$PLUGIN/hooks/statusline.py'")
[[ "$OUT" == *"7d 35%"* && "$OUT" != *"5h 27%"* ]] && ok "rate limit floor" || bad "rate limit floor"

# a payload with no effort/thinking/limits must not leave empty separators behind
OUT=$(echo "{\"session_id\":\"bare\",\"context_window\":{\"used_percentage\":5},\"model\":{\"display_name\":\"Opus 5\"},\"workspace\":{\"current_dir\":\"/home/u/proj\"}}" | python3 "$PLUGIN/hooks/statusline.py")
[[ "$OUT" == "[OK] ctx 5% | Opus 5 | proj" ]] && ok "empty segments dropped" || bad "empty segments dropped (got: $OUT)"

echo "== 15. thresholds follow the auto-compact point =="
OUT=$(CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=70 bash -c "echo '$FULL' | python3 '$PLUGIN/hooks/statusline.py'")
echo "  output: $OUT"
[[ "$OUT" == *"ctx 24% → auto 70%"* ]] && ok "auto-compact point shown" || bad "auto-compact point shown"
# auto 70 => notice 55, warn 65. 62% must be NOTICE, not the stock-default OK.
echo "{\"session_id\":\"auto\",\"context_window\":{\"used_percentage\":62},\"model\":{\"id\":\"m\",\"display_name\":\"M\"},\"workspace\":{\"current_dir\":\"/x\"}}" | python3 "$PLUGIN/hooks/statusline.py" >/dev/null
OUT=$(CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=70 bash -c "echo '{\"session_id\":\"auto\"}' | python3 '$PLUGIN/hooks/prompt-submit.py'")
echo "  output: $OUT"
[[ "$OUT" == *"NOTICE"* && "$OUT" == *">= 55%"* && "$OUT" == *"Auto-compact fires at 70%"* ]] \
  && ok "derived notice threshold" || bad "derived notice threshold"
# 66% must be CRITICAL under auto=70 (warn 65), though it is below the stock 75
echo "{\"session_id\":\"auto2\",\"context_window\":{\"used_percentage\":66},\"model\":{\"id\":\"m\",\"display_name\":\"M\"},\"workspace\":{\"current_dir\":\"/x\"}}" | python3 "$PLUGIN/hooks/statusline.py" >/dev/null
OUT=$(CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=70 bash -c "echo '{\"session_id\":\"auto2\"}' | python3 '$PLUGIN/hooks/prompt-submit.py'")
[[ "$OUT" == *"CRITICAL"* && "$OUT" == *">= 65%"* ]] && ok "derived warn threshold" || bad "derived warn threshold"
# an explicit setting still wins over the derived one: 66% is CRITICAL at auto=70,
# but silent once the thresholds are pinned above it
echo "{\"session_id\":\"auto3\",\"context_window\":{\"used_percentage\":66},\"model\":{\"id\":\"m\",\"display_name\":\"M\"},\"workspace\":{\"current_dir\":\"/x\"}}" | python3 "$PLUGIN/hooks/statusline.py" >/dev/null
OUT=$(CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=70 CONTEXT_CHECKER_WARN_PCT=90 CONTEXT_CHECKER_NOTICE_PCT=80 \
  bash -c "echo '{\"session_id\":\"auto3\"}' | python3 '$PLUGIN/hooks/prompt-submit.py'")
[[ -z "$OUT" ]] && ok "explicit thresholds win" || bad "explicit thresholds win (got: ${OUT:0:60})"

echo "== 16. subagent status line renders per-agent context % =="
SUB="{\"columns\":80,\"tasks\":[
 {\"id\":\"t1\",\"name\":\"Explore\",\"description\":\"search auth flow\",\"tokenCount\":62000,\"contextWindowSize\":1000000},
 {\"id\":\"t2\",\"name\":\"code-reviewer\",\"description\":\"review diff\",\"tokenCount\":124000,\"contextWindowSize\":200000},
 {\"id\":\"t3\",\"name\":\"pending\",\"description\":\"model unresolved\"}]}"
OUT=$(echo "$SUB" | python3 "$PLUGIN/hooks/subagent-statusline.py")
echo "$OUT" | sed 's/^/  /'
[[ $(echo "$OUT" | grep -c .) -eq 2 ]] && ok "only rows we can improve are emitted" || bad "row count"
echo "$OUT" | grep -q '"id": "t1"' && echo "$OUT" | grep -q '\[OK\] Explore · search auth flow · 6.2%' \
  && ok "t1 rendered OK at 6.2%" || bad "t1 rendered"
# 62% is past the 60% notice line but short of 75%, so it is WARN, not CRIT —
# the same mapping the main bar uses.
echo "$OUT" | grep -q '\[WARN\] code-reviewer · review diff · 62%' \
  && ok "t2 rendered WARN at 62%" || bad "t2 rendered"
echo "$OUT" | grep -q '"t3"' && bad "t3 should be left to default rendering" || ok "t3 left to default"
echo "$OUT" | while read -r l; do [ -n "$l" ] && python3 -c "import json,sys;json.loads(sys.argv[1])" "$l" || exit 1; done \
  && ok "output lines are valid JSON" || bad "output lines are valid JSON"

echo "== 16b. subagent rows respect the column budget =="
NARROW="{\"columns\":40,\"tasks\":[{\"id\":\"t1\",\"name\":\"Explore\",\"description\":\"$(printf 'x%.0s' {1..200})\",\"tokenCount\":1000,\"contextWindowSize\":200000}]}"
LEN=$(echo "$NARROW" | python3 "$PLUGIN/hooks/subagent-statusline.py" | python3 -c "import json,sys;print(len(json.loads(sys.stdin.readline())['content']))")
[[ "$LEN" -le 40 ]] && ok "content fits in 40 columns (got $LEN)" || bad "content fits in 40 columns (got $LEN)"
OUT=$(echo "$NARROW" | python3 "$PLUGIN/hooks/subagent-statusline.py")
[[ "$OUT" == *"0.5%"* ]] && ok "percentage survives truncation" || bad "percentage survives truncation"

echo "== 16c. subagent hook survives junk =="
for payload in 'not json' '{}' '{"tasks":"nope"}' '{"tasks":[null,{"id":"x"},{"name":"no id"}]}'; do
  echo "$payload" | python3 "$PLUGIN/hooks/subagent-statusline.py" >/dev/null 2>&1
  [[ $? -eq 0 ]] && ok "survives: ${payload:0:22}" || bad "survives: ${payload:0:22}"
done

echo "== 17. plugin settings.json declares the subagent status line =="
python3 -c "
import json,sys
d=json.load(open('$PLUGIN/settings.json'))
assert set(d) <= {'agent','subagentStatusLine'}, d       # only these keys are supported
assert d['subagentStatusLine']['type']=='command'
print(d['subagentStatusLine']['command'])
" > "$SANDBOX/sub.cmd" && ok "settings.json shape" || bad "settings.json shape"
SUBCMD=$(cat "$SANDBOX/sub.cmd" 2>/dev/null)
OUT=$(CLAUDE_PLUGIN_ROOT="$PLUGIN" sh -c "echo '$SUB' | $SUBCMD" 2>&1)
[[ $? -eq 0 && "$OUT" == *'"t1"'* ]] && ok "declared command runs and renders" || bad "declared command runs (${OUT:0:60})"

echo "== 18. run.sh picks a working interpreter =="
RUN="$PLUGIN/hooks/run.sh"
STATUS_PAYLOAD="{\"session_id\":\"run\",\"context_window\":{\"used_percentage\":42},\"model\":{\"id\":\"m\",\"display_name\":\"M\"},\"workspace\":{\"current_dir\":\"/home/u/proj\"}}"
OUT=$(echo "$STATUS_PAYLOAD" | sh "$RUN" "$PLUGIN/hooks/statusline.py")
[[ "$OUT" == "[OK] ctx 42% | M | proj" ]] && ok "probes and runs" || bad "probes and runs (got: $OUT)"

OUT=$(echo "$STATUS_PAYLOAD" | CONTEXT_CHECKER_PYTHON=$(command -v python3) sh "$RUN" "$PLUGIN/hooks/statusline.py")
[[ "$OUT" == "[OK] ctx 42% | M | proj" ]] && ok "explicit interpreter honoured" || bad "explicit interpreter honoured"

# A stub that behaves like the Windows Store alias — stderr, non-zero, reads no
# stdin — must be skipped rather than accepted as a working interpreter.
STUBDIR="$SANDBOX/stub"; mkdir -p "$STUBDIR"
cat > "$STUBDIR/python3" <<'STUB'
#!/bin/sh
echo "Python was not found; run without arguments to install from the Microsoft Store" >&2
exit 49
STUB
chmod +x "$STUBDIR/python3"
ln -sf "$(command -v python3)" "$STUBDIR/python"
OUT=$(echo "$STATUS_PAYLOAD" | PATH="$STUBDIR:/usr/bin:/bin" sh "$RUN" "$PLUGIN/hooks/statusline.py" 2>/dev/null)
[[ "$OUT" == "[OK] ctx 42% | M | proj" ]] && ok "skips a non-working python3 stub" \
  || bad "skips a non-working python3 stub (got: $OUT)"

echo "not-json" | sh "$RUN" "$PLUGIN/hooks/statusline.py" >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "launcher passes through hook exit code" || bad "launcher passes through hook exit code"

sh "$RUN" >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "missing argument is an error" || bad "missing argument is an error"

EMPTY="$SANDBOX/empty"; mkdir -p "$EMPTY"
PATH="$EMPTY" sh "$RUN" "$PLUGIN/hooks/statusline.py" </dev/null >/dev/null 2>&1
[[ $? -eq 127 ]] && ok "reports when no interpreter exists" || bad "reports when no interpreter exists"

echo "== 19. non-UTF-8 console (Windows cp932) =="
# Regression: on a Japanese Windows console Python defaults to cp932, which cannot
# encode the middle dot these lines use, nor a project directory with a Japanese
# name. Printing raised UnicodeEncodeError and the hook died; on the way in, the
# payload failed to decode and the hook silently did nothing.
JP="{\"session_id\":\"cp932\",\"context_window\":{\"used_percentage\":33},\"model\":{\"id\":\"m\",\"display_name\":\"Opus 5\"},\"workspace\":{\"current_dir\":\"/home/u/日本語プロジェクト\"},\"effort\":{\"level\":\"high\"},\"thinking\":{\"enabled\":true}}"
OUT=$(echo "$JP" | PYTHONIOENCODING=cp932 python3 "$PLUGIN/hooks/statusline.py" 2>&1)
echo "  output: $OUT"
[[ "$OUT" == "[OK] ctx 33% | Opus 5 | high·think | 日本語プロジェクト" ]] \
  && ok "statusline survives cp932 in and out" || bad "statusline survives cp932 (got: $OUT)"

# the state file must still be readable UTF-8, not mangled by the console encoding
python3 -c "
import json
d=json.load(open('$HOME/.claude/tmp/context-checker/cp932.json', encoding='utf-8'))
assert d['cwd'].endswith('日本語プロジェクト'), d['cwd']
" && ok "state file keeps UTF-8" || bad "state file keeps UTF-8"

OUT=$(echo "{\"session_id\":\"cp932\",\"transcript_path\":\"$TRANSCRIPT\"}" | PYTHONIOENCODING=cp932 python3 "$PLUGIN/hooks/prompt-submit.py" 2>&1)
[[ "$OUT" != *"UnicodeEncodeError"* && "$OUT" != *"Traceback"* ]] \
  && ok "prompt-submit survives cp932" || bad "prompt-submit survives cp932"

SUBJP="{\"columns\":80,\"tasks\":[{\"id\":\"t1\",\"name\":\"探索\",\"description\":\"認証フローを調べる\",\"tokenCount\":62000,\"contextWindowSize\":1000000}]}"
OUT=$(echo "$SUBJP" | PYTHONIOENCODING=cp932 python3 "$PLUGIN/hooks/subagent-statusline.py" 2>&1)
echo "  subagent: $OUT"
echo "$OUT" | grep -q '探索 · 認証フローを調べる · 6.2%' \
  && ok "subagent row survives cp932" || bad "subagent row survives cp932"

OUT=$(echo "{\"session_id\":\"cp932jp\",\"trigger\":\"manual\",\"transcript_path\":\"$TRANSCRIPT\"}" | PYTHONIOENCODING=cp932 python3 "$PLUGIN/hooks/pre-compact.py" 2>&1)
CKJP=$(cat "$HOME/.claude/checkpoints/context-checker/cp932jp.latest" 2>/dev/null)
[[ -f "$CKJP" ]] && grep -q "最初の依頼です" "$CKJP" \
  && ok "pre-compact writes UTF-8 under cp932" || bad "pre-compact writes UTF-8 under cp932"

echo
rm -rf "$SANDBOX"
if [[ $fail -eq 0 ]]; then echo "ALL PASS"; else echo "FAILURES PRESENT"; fi
exit $fail
