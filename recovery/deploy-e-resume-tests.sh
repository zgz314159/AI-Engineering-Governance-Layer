#!/usr/bin/env bash
# deploy-e-resume-tests.sh — targeted checks for install restart + E resume glue.
# Does NOT re-run broker 18 / stack 9 / deploy-glue 7.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AEGL_ROOT="$(cd "$SELF_DIR/.." && pwd)"
STACK="$AEGL_ROOT/recovery/promote-to-main-stack.sh"
INST="$AEGL_ROOT/recovery/install-broker.sh"
PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# 1. install-broker: controlled restart + active + socket (not enable --now alone)
if grep -q 'systemctl restart aegl-promote-broker' "$INST" \
   && grep -q 'is-active --quiet aegl-promote-broker' "$INST" \
   && grep -q 'broker.sock' "$INST"; then
  ok "install-broker restarts and checks active+socket"
else
  no "install-broker missing restart/active/socket checks"
fi
if grep -qE 'enable --now aegl-promote-broker' "$INST"; then
  no "install-broker still uses enable --now as sole start path"
else
  ok "install-broker does not rely on enable --now alone"
fi

# 2. stack: print RC+JSON before stop; set +e around client
if grep -q 'BROKER_.*_RC=' "$STACK" && grep -q 'BROKER_.*_JSON=' "$STACK" \
   && grep -q 'set +e' "$STACK"; then
  ok "stack prints broker RC/JSON with set +e capture"
else
  no "stack missing print-before-stop broker capture"
fi
# Must not assert inside command substitution that can hide JSON under set -e
if grep -nE 'REG_OUT="\$\("\$BROKER_BIN".*assert' "$STACK"; then
  no "stack still asserts inside broker capture"
else
  ok "stack does not assert inside broker capture"
fi

# 3. resume-from-E mode present; skips restore/ACL/registry wipe
if grep -q '\-\-resume-from-E' "$STACK" && grep -q 'STACK_MODE=resume-from-E' "$STACK"; then
  ok "resume-from-E mode wired"
else
  no "resume-from-E mode missing"
fi
# resume path must check main baseline and installed hashes
if grep -q '6f495c45b67a0217034be2510068b2bc56c85607' "$STACK" \
   && grep -q 'verify_installed_matches_commit' "$STACK" \
   && grep -q 'hash mismatch' "$STACK"; then
  ok "resume checks main baseline + installed==commit"
else
  no "resume precondition checks incomplete"
fi
# resume must not call restore or install-broker/acl
python3 - "$STACK" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read().splitlines()
# Extract resume branch body roughly: from MODE=resume-from-E exit block
start = None
for i,l in enumerate(text):
    if 'if [ "$MODE" = resume-from-E ]' in l or "MODE\" = resume-from-E" in l:
        start = i
        break
if start is None:
    sys.exit(1)
# until exit 0 of that branch
body = []
for l in text[start:]:
    body.append(l)
    if l.strip() == "exit 0":
        break
blob = "\n".join(body)
banned = ["install-broker.sh", "install-promote-target-acl.sh", "git restore", "registry.json"]
# allow comments mentioning them
for b in banned:
    for line in body:
        if b in line and not line.lstrip().startswith("#") and "verify" not in line and "NOT" not in line.upper():
            # install-broker must not be invoked in resume body
            if "bash -s" in line or "restore --source" in line or "rm " in line and "registry" in line:
                print("banned:", line)
                sys.exit(1)
if "verify_resume_preconditions" not in blob or "run_promote_and_close" not in blob:
    sys.exit(1)
if "install-broker.sh" in blob and "| bash" in blob:
    sys.exit(1)
sys.exit(0)
PY
[ $? -eq 0 ] && ok "resume skips restore/ACL/registry wipe" || no "resume still touches deploy/restore"

echo "DEPLOY_E_RESUME_TESTS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
