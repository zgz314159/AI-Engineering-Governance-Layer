#!/usr/bin/env bash
# Focused check for THIS round's acceptance tightening ONLY:
#   * capture sampling rejects a launcher wrapper and finds the real Hermes entry
#   * the installer's guard-log parser is exercised on a fixture (through the REAL code)
#   * the guard-state mount + handoff wiring is present
set -u
AEGL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INST="$AEGL_ROOT/recovery/install-model-broker.sh"
LAUNCH="$AEGL_ROOT/bin/aegl-hermes-sandbox"
PASS=0; FAIL=0
ok(){ printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
no(){ printf '  FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

# === 1. sampling: wrapper must not be mistaken for Hermes ======================== #
T="$(mktemp -d)"
cat > "$T/hermes" <<'EOS'
#!/bin/sh
sleep 20
EOS
chmod +x "$T/hermes"
# a wrapper whose ARGUMENTS mention hermes/chat, running an interpreter over the entry
cat > "$T/wrap.sh" <<EOS
#!/bin/bash
"$T/hermes" -p android-stack chat --oneshot &
sleep 20
EOS
bash "$T/wrap.sh" & WRAP=$!
sleep 0.5
printf '{"child-pid": %d}\n' "$WRAP" > "$T/info.json"
EV="$(python3 "$AEGL_ROOT/recovery/capture_evidence.py" "$T/info.json" --max-wait 5 --hermes-wait 5)"
HP="$(printf '%s' "$EV" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("hermes_pid",""))' 2>/dev/null)"
if [ -n "$HP" ]; then
  CMD="$(tr '\0' ' ' < "/proc/$HP/cmdline" 2>/dev/null)"
  case "$CMD" in *"$T/hermes"*) ok "sampling found the real entry (pid $HP), not the wrapper";; *) no "sampling matched the wrong process: $CMD";; esac
else
  no "sampling found no Hermes entry ($EV)"
fi
kill "$WRAP" 2>/dev/null; wait "$WRAP" 2>/dev/null; rm -rf "$T"

# === 2. the installer's guard-log parser, run from the REAL source =============== #
LOG="$(mktemp)"; WT_F="/tmp/trial-wt"
printf '%s\n' \
 '{"decision":"ALLOW","class":"CONTRACT_ALLOWED_SOURCE","target":"/tmp/trial-wt/out.txt"}' \
 '{"decision":"BLOCK","class":"OUT_OF_CONTRACT_SCOPE","target":"/home/zhong/Projects/Official/x"}' \
 '{"decision":"ALLOW","class":"CONTRACT_ALLOWED_SOURCE","target":"/tmp/trial-wt/ro-probe/breach"}' \
 '{"decision":"BLOCK","class":"UNCLASSIFIED","target":"/tmp/trial-wt/other"}' > "$LOG"
PARSER="$T.parser.py"
awk '/python3 - "\$ST\/guard-decisions.jsonl"/{f=1;next} f&&/^PY$/{exit} f{print}' "$INST" > "$PARSER"
grep -q 'osallow' "$PARSER" && ok "extracted the installer's real guard-log parser" || no "parser not found in the installer"
OUT="$(python3 "$PARSER" "$LOG" "/home/zhong/Projects/Official" "$WT_F" "ro-probe" 2>/dev/null)"
[ "$OUT" = "1 2 1" ] && ok "parser counts: blocked-forbidden=1 allowed-task=2 allowed-osprobe=1" || no "parser counts wrong: '$OUT'"
OUT2="$(python3 "$PARSER" /nonexistent "/home/zhong/Projects/Official" "$WT_F" "ro-probe" 2>/dev/null)"
[ "$OUT2" = "0 0 0" ] && ok "no log -> no evidence (stays NOT_PROVEN)" || no "missing log produced evidence: '$OUT2'"
rm -f "$LOG" "$PARSER"

# === 3. wiring is present ======================================================== #
grep -q 'AEGL_TRIAL_GUARD_LOG' "$LAUNCH" && grep -q 'AEGL_TRIAL_GUARD_LOG' "$INST" && ok "guard log handoff is wired on both sides" || no "guard log handoff missing"
grep -q 'stack_paths.guard_state_root' "$LAUNCH" && ok "guard state root is derived, not hardcoded" || no "guard state root not derived"
grep -q 'ro-probe/.probe' "$INST" && ok "trusted controller OS-protection probe present" || no "OS probe missing"
grep -q 'NOT_PROVEN' "$INST" && ok "missing evidence still defaults to NOT_PROVEN" || no "NOT_PROVEN default removed"

echo "ACCEPTANCE_TESTS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
