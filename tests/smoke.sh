#!/bin/bash
# Smoke test for context-checker hooks against mock payloads.
set -u
PLUGIN=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SANDBOX=$(mktemp -d)
export HOME="$SANDBOX"
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
[[ "$OUT" == *"CRITICAL"* && "$OUT" == *"estimated from transcript"* && "$OUT" == *"80.0%"* ]] \
  && ok "declared-window estimate" || bad "declared-window estimate"
# same transcript, 1M window -> 16.0%, below every threshold -> silence
OUT=$(CONTEXT_CHECKER_CONTEXT_WINDOW=1000000 bash -c "echo '{\"session_id\":\"declared1m\",\"transcript_path\":\"$TRANSCRIPT\"}' | python3 '$PLUGIN/hooks/prompt-submit.py'")
[[ -z "$OUT" ]] && ok "window size respected (1M -> quiet)" || bad "window size respected (1M -> quiet)"

echo "== 7. prompt-submit: threshold override via env =="
echo "{\"session_id\":\"envtest\",\"context_window\":{\"used_percentage\":20},\"model\":{\"id\":\"claude-opus-5\",\"display_name\":\"Opus 5\"},\"workspace\":{\"current_dir\":\"/x\"}}" | python3 "$PLUGIN/hooks/statusline.py" >/dev/null
OUT=$(CONTEXT_CHECKER_NOTICE_PCT=10 CONTEXT_CHECKER_WARN_PCT=90 bash -c "echo '{\"session_id\":\"envtest\",\"transcript_path\":\"$TRANSCRIPT\"}' | python3 '$PLUGIN/hooks/prompt-submit.py'")
echo "  output: $OUT"
[[ "$OUT" == *"NOTICE"* && "$OUT" == *"20.0%"* && "$OUT" == *">= 10.0%"* ]] && ok "env thresholds" || bad "env thresholds"

echo "== 7b. sidechain usage records are ignored =="
SIDEC="$SANDBOX/side.jsonl"
cp "$TRANSCRIPT" "$SIDEC"
echo '{"isSidechain":true,"message":{"role":"assistant","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":999999,"output_tokens":1},"model":"claude-opus-5"}}' >> "$SIDEC"
OUT=$(CONTEXT_CHECKER_CONTEXT_WINDOW=200000 bash -c "echo '{\"session_id\":\"sidechain\",\"transcript_path\":\"$SIDEC\"}' | python3 '$PLUGIN/hooks/prompt-submit.py'")
[[ "$OUT" == *"80.0%"* ]] && ok "sidechain skipped" || bad "sidechain skipped (got: ${OUT:0:60})"

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

echo
rm -rf "$SANDBOX"
if [[ $fail -eq 0 ]]; then echo "ALL PASS"; else echo "FAILURES PRESENT"; fi
exit $fail
