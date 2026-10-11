#!/usr/bin/env bash
# Focused checks for the trial-entry fixes of this round ONLY:
#   1. self_test variable init order (PROJ before WT, in separate statements)
#   2. the contract is compiled by a NORMAL user (never root) outside the project,
#      and the trusted side verifies a FIXED file list and freezes the package
#   3. evidence: FACTS is self-report; guard/os are NOT_PROVEN and the gate stays FAILED
# It does NOT re-run the 20+ prior checks or any other suite.
set -u
AEGL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INST="$AEGL_ROOT/recovery/install-model-broker.sh"
PASS=0; FAIL=0
ok(){ printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
no(){ printf '  FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

# --- 1. variable init order (self_test function body only) --------------------- #
BODY="$(awk '/^self_test\(\)\{/,/^\}/' "$INST")"
printf '%s\n' "$BODY" | grep -qE '^  local PROJ=.*$' && ok "self_test declares PROJ on its own line" || no "PROJ not on its own line"
printf '%s\n' "$BODY" | grep -qE '^  local WT="\$PROJ/trial-wt"$' && ok "self_test declares WT on its own line (after PROJ)" || no "WT not declared separately"
# same class: no `local A=.. B="$A/.."` referencing a sibling declared in the same statement
if printf '%s\n' "$BODY" | grep -nE '^  local .*=' | grep -qE 'local ([A-Za-z_][A-Za-z0-9_]*)=[^ ]* ([A-Za-z_][A-Za-z0-9_]*)=.*\$\1'; then
  no "a local references a sibling declared in the same statement"
else
  ok "no same-statement local cross-reference in self_test"
fi

# --- 2. compiler identity + trusted fixed-list freeze -------------------------- #
printf '%s\n' "$BODY" | grep -q 'COMPILER_USER="${SUDO_USER:-zhong}"' && ok "self_test uses a normal compiler identity" || no "no COMPILER_USER"
printf '%s\n' "$BODY" | grep -q 'runuser -u "$COMPILER_USER" -- python3 "$LIBDIR/make_trial_contract.py"' && ok "the contract is compiled as the normal user (not root)" || no "compile not run as the normal user"
printf '%s\n' "$BODY" | grep -q 'for f in PRODUCT.md ' && ok "trusted side verifies a FIXED file list" || no "no fixed file list"
printf '%s\n' "$BODY" | grep -q 'chown -R root:root "$CONTRACT"; chmod -R a-w "$CONTRACT"' && ok "the package is frozen root-owned a-w" || no "package not frozen"

# --- 3. evidence separation / fail-closed ------------------------------------- #
printf '%s\n' "$BODY" | grep -q 'guard_state="NOT_PROVEN" os_state="NOT_PROVEN"' && ok "guard/os default to NOT_PROVEN (FACTS is self-report)" || no "isolation checks not NOT_PROVEN"
printf '%s\n' "$BODY" | grep -q 'isolation checks \$guard_state/\$os_state — gate stays FAILED' && ok "the gate stays FAILED while the isolation checks are unproven" || no "no fail-closed enforcement"

# --- runnable: compile as THIS (normal) user, outside any project -------------- #
ST="$(mktemp -d)"; FC="$ST/fc"; PKG="$ST/pkg"
mkdir -p "$FC/Google-Android-Agent-Development-Stack/trial-wt"; echo TOK > "$FC/Google-Android-Agent-Development-Stack/trial-wt/INPUT.txt"
if python3 "$AEGL_ROOT/recovery/make_trial_contract.py" --projects-root "$FC" \
     --allowed "Google-Android-Agent-Development-Stack/trial-wt/" \
     --forbidden "Google-Android-Agent-Development-Stack/reports/,KeepLab-Relay/" \
     --read-first "Google-Android-Agent-Development-Stack/trial-wt/INPUT.txt" --out "$PKG" >/dev/null 2>&1; then
  ok "contract compiles as $(id -un) outside any project"
else
  no "contract compile failed (as $(id -un))"
fi
MISS=0
for f in PRODUCT.md requirements.md design.md tasks.md DESIGN.md acceptance.md project-context.json \
         verification-intent.json manifest.json implementation-contract.json READY.json EXECUTOR-PROMPT.md; do
  [ -f "$PKG/$f" ] || { MISS=1; echo "    missing: $f"; }
done
[ "$MISS" = 0 ] && ok "the fixed 12-file list is present" || no "the fixed file list is incomplete"
rm -rf "$ST"

echo "ENTRY_FIX_TESTS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
