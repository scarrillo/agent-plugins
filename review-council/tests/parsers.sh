#!/usr/bin/env bash
# parsers.sh — check the member reply parsers in review-fanout.sh against saved
# output shapes, so a CLI format change fails here instead of losing a member.
# usage: bash tests/parsers.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd); FIX="$HERE/fixtures"
TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
eval "$(sed -n '/^claude_reply()/,/^}/p;/^copilot_reply()/,/^}/p;/^agy_reply()/,/^}/p;/^agy_pick()/,/^}/p' "$HERE/../scripts/review-fanout.sh")"
fails=0
check() {  # label parser fixture expected-stdout expected-reply expected-problem
  local out reply problem rc
  rm -f "$TMP/reply" "$TMP/problem"
  out=$("$2" "$FIX/$3" "$TMP/reply" "$TMP/problem" 2> "$TMP/err"); rc=$?
  reply=$(cat "$TMP/reply" 2>/dev/null); problem=$(cat "$TMP/problem" 2>/dev/null)
  if [ "$rc" = 0 ] && [ "$out" = "$4" ] && [ "$reply" = "$5" ] && [ "$problem" = "$6" ]; then
    echo "ok    $1"
  else
    echo "FAIL  $1: rc=$rc out='$out' reply='$reply' problem='$problem' err='$(head -c 120 "$TMP/err")'"; fails=$((fails + 1))
  fi
}
V="Verdict: APPROVE"
check "claude single object" claude_reply claude-object.json model-a "$V" ""
check "claude event list"    claude_reply claude-events.json model-a "$V" ""
check "claude error result"  claude_reply claude-error.json model-a "" "claude error: error_max_turns"
check "claude no result"     claude_reply claude-no-result.json unknown "" "claude unparsed-json (see log)"
check "claude garbage"       claude_reply garbage.json unknown "" "claude unparsed-json (see log)"
check "copilot events"       copilot_reply copilot-ok.jsonl "model-b (Fusion/balance picked model-b)" "$V" ""
check "copilot quota"        copilot_reply copilot-quota.jsonl unknown "" "copilot quota exceeded"
check "copilot untrusted"    copilot_reply copilot-untrusted.jsonl unknown "" "copilot folder not trusted (add it to trustedFolders in ~/.copilot/config.json)"
check "copilot garbage"      copilot_reply garbage.json unknown "" "copilot unparsed-json (see log)"
check "agy object"           agy_reply agy-ok.json SUCCESS "$V" ""
check "agy array"            agy_reply agy-array.json "unparsed-json (see log)" "" ""
check "agy garbage"          agy_reply garbage.json "unparsed-json (see log)" "" ""
# agy_pick: first AGY_MODEL_ORDER family offered at the effort (fixture has no neon).
pick() {  # label expected effort family...
  local label=$1 want=$2 got; shift 2
  got=$(agy_pick "$@" < "$FIX/agy-models.txt")
  if [ "$got" = "$want" ]; then echo "ok    $label"; else echo "FAIL  $label: got '$got' want '$want'"; fails=$((fails + 1)); fi
}
pick "agy pick skips missing neon" gemini-4-carbon high gemini-4-neon gemini-4-carbon gemini-3.8-flash
pick "agy pick needs the effort"   gemini-3.8-flash low gemini-4-neon gemini-4-carbon gemini-3.8-flash
pick "agy pick none available"     "" xhigh gemini-4-neon gemini-4-carbon gemini-3.8-flash
pick "agy pick no prefix match"    "" high gemini-4
# settings.sh: AGY_MODEL_ORDER holds families only.
S="$HERE/../scripts/settings.sh"
setchk() {  # label expect(ok|bad) value
  if AGY_MODEL_ORDER=$3 bash "$S" get AGY_MODEL_ORDER 2>/dev/null | grep -qxF -- "$3"; then r=ok; else r=bad; fi
  if [ "$r" = "$2" ]; then echo "ok    $1"; else echo "FAIL  $1: got $r"; fails=$((fails + 1)); fi
}
setchk "order accepts families"       ok  "gemini-4-neon, gemini-3.8-flash"
setchk "order rejects effort suffix"  bad "gemini-4-neon-high, gemini-3.8-flash"
[ "$fails" = 0 ] && echo "all parser checks passed" || { echo "$fails parser check(s) failed"; exit 1; }
