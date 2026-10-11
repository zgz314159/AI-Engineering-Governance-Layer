#!/usr/bin/env bash
# Focused check for THIS round only: the capability handoff to the fixed trusted drop
# entry. It uses the ACTUAL generated argv and really runs drop_verify (positive + the two
# fail-closed negatives). It does not pass by grepping code.
set -u
AEGL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DV="$AEGL_ROOT/recovery/drop_verify.py"
PASS=0; FAIL=0
ok(){ printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
no(){ printf '  FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

# === 1. the actual argv carries the minimal cap whitelist + the drop entry ========== #
ARGV="$(python3 - "$AEGL_ROOT/recovery/sandbox_spec.py" "$DV" <<'PY'
import importlib.util, sys
m = importlib.util.module_from_spec(importlib.util.spec_from_file_location("ss", sys.argv[1]))
importlib.util.spec_from_file_location("ss", sys.argv[1]).loader.exec_module(m)
argv = m.build(bwrap="/usr/bin/bwrap", uid="994", gid="972", run="/run/t", wt="/tmp/wt",
               scr="/tmp/scr", runtime="/home/zhong/.hermes/hermes-agent",
               tools="/home/zhong/.hermes/tools", entry="/home/zhong/.local/bin/hermes",
               installs="/home/zhong/.hermes/installs", guard_src="/g", guard_dest="/home/zhong/g",
               contract_package="/pkg", setpriv="/usr/bin/setpriv", drop_verify=sys.argv[2],
               hermes_args=["hermes"])["argv"]
print("\n".join(argv))
PY
)"
ONE="$(printf '%s\n' "$ARGV" | tr '\n' ' ')"
grep -q -- '--cap-drop ALL' <<<"$ONE" && ok "argv drops ALL capabilities first" || no "--cap-drop ALL missing"
for c in CAP_SETUID CAP_SETGID CAP_SETPCAP; do
  grep -q -- "--cap-add $c" <<<"$ONE" && ok "capability whitelisted: $c" || no "capability missing: $c"
done
grep -q -- '--cap-add ALL' <<<"$ONE" && no "argv adds ALL capabilities" || ok "argv never adds ALL capabilities"
for f in --clear-groups --no-new-privs --bounding-set=-all --inh-caps=-all --ambient-caps=-all; do
  grep -q -- "$f" <<<"$ONE" && ok "drop flag present: $f" || no "drop flag missing: $f"
done
grep -q -- "python3 $DV --uid 994 --gid 972" <<<"$ONE" && ok "the fixed trusted drop entry verifies uid/gid before the runner" || no "drop_verify is not wired before the runner"

# === 2. real fail-closed verification ============================================ #
# NOTE: --clear-groups, --bounding-set=-all and the full drop need CAP_SETGID/CAP_SETPCAP,
# which bwrap grants only inside the real sandbox; unprivileged we use --keep-groups and
# omit --bounding-set, so the groups check is the ONE thing that cannot be satisfied here.
T="$(mktemp -d)"
UID_="$(id -u)"; GID_="$(id -g)"
SP=("$UID_" "$GID_")
OUT="$(setpriv --reuid "$UID_" --regid "$GID_" --keep-groups --no-new-privs \
       --inh-caps=-all --ambient-caps=-all \
       -- python3 "$DV" --uid "$UID_" --gid "$GID_" -- /bin/echo EXEC_OK 2>&1)"; RC=$?
grep -q 'caps=eff:0000000000000000 prm:0000000000000000 inh:0000000000000000 amb:0000000000000000' <<<"$OUT" \
  && ok "reads the real kernel state: all four capability sets are 0" || no "capability sets not cleared/read: $OUT"
grep -q 'nnp=1' <<<"$OUT" && ok "reads the real restriction state: NoNewPrivs=1" || no "NoNewPrivs not 1: $OUT"
{ [ "$RC" != 0 ] && grep -q 'DROP_HANDOFF_FAIL' <<<"$OUT" && grep -qi 'supplementary groups' <<<"$OUT"; } \
  && ok "positive(partial): uid/gid/caps/nnp OK; refuses only on groups it cannot clear here" \
  || no "partial positive did not behave as expected ($RC): $OUT"
grep -q 'EXEC_OK' <<<"$OUT" && no "the runner started despite the failed check" || ok "the runner did NOT start on a failed check"
printf '  NOTE: the full positive (with --clear-groups) needs the bwrap caps -> NOT_RUN here\n'

OUT="$(python3 "$DV" --uid "$UID_" --gid "$GID_" -- /bin/sh -c "touch '$T/ran1'" 2>&1)"; RC=$?
{ [ "$RC" != 0 ] && grep -q 'DROP_HANDOFF_FAIL' <<<"$OUT" && grep -qi 'NoNewPrivs' <<<"$OUT"; } \
  && ok "no_new_privs not set -> refuses and stops" || no "missing no_new_privs did not fail closed ($RC): $OUT"
[ ! -e "$T/ran1" ] && ok "the command did NOT run after a failed handoff" || no "the command ran despite a failed handoff"

OUT="$(setpriv --reuid "$UID_" --regid "$GID_" --keep-groups --no-new-privs \
       --inh-caps=-all --ambient-caps=-all \
       -- python3 "$DV" --uid 12345 --gid "$GID_" -- /bin/sh -c "touch '$T/ran2'" 2>&1)"; RC=$?
{ [ "$RC" != 0 ] && grep -q 'DROP_HANDOFF_FAIL' <<<"$OUT" && grep -qi 'uid' <<<"$OUT"; } \
  && ok "uid mismatch -> refuses and stops" || no "uid mismatch did not fail closed ($RC): $OUT"
[ ! -e "$T/ran2" ] && ok "the command did NOT run on a uid mismatch" || no "the command ran on a uid mismatch"

rm -rf "$T"
echo "ENTRY_CAP_TESTS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
