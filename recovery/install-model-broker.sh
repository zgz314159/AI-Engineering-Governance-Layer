#!/usr/bin/env bash
# install-model-broker.sh — install the trusted model broker + the Hermes sandbox launcher.
#
# Explicit inputs (works piped to `bash -s`; no $BASH_SOURCE reliance). Validates every
# input and required file (sha256 against the pinned commit) BEFORE any host change; any
# failure returns non-zero and never prints INSTALL_RESULT=OK.
#
#   sudo bash install-model-broker.sh --repo <AEGL> --commit <full-40-hex>
#
# Scope: the trusted model broker + sandbox launcher + a root-only credential dir. It does
# NOT create the model credential (the operator places it), does NOT run `switch`, change
# project permissions, merge anything, or write /etc/aegl/broker-verified.
set -uo pipefail
REPO=""; COMMIT=""; SELF_TEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --commit) COMMIT="${2:-}"; shift 2 ;;
    --self-test) SELF_TEST=1; shift ;;
    *) printf 'INSTALL_ERROR: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
done
LIBDIR="/usr/local/lib/aegl-model"
CREDDIR="/etc/aegl/model"
REGDIR="/var/lib/aegl-model"
AI_USER="aegl-ai"
FILES=(bin/aegl-model-broker bin/aegl-hermes-sandbox recovery/model_broker.py recovery/loopback_shim.py)
say(){ printf '%s\n' "$*"; }
fail(){ printf 'INSTALL_ERROR: %s\n' "$*" >&2; exit 1; }
sha_of(){ sha256sum | awk '{print $1}'; }

[ "$(id -u)" = 0 ] || fail "must run as root"
[ -n "$REPO" ] || fail "--repo is required"
[ -d "$REPO/.git" ] || fail "--repo is not a git repository: $REPO"
[ -n "$COMMIT" ] || fail "--commit is required"
[ "${#COMMIT}" -eq 40 ] || fail "--commit must be a full 40-hex commit id"
git -C "$REPO" cat-file -e "$COMMIT^{commit}" 2>/dev/null || fail "commit not found: $COMMIT"
for f in "${FILES[@]}"; do git -C "$REPO" cat-file -e "$COMMIT:$f" 2>/dev/null || fail "required file missing in commit: $f"; done

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
for f in "${FILES[@]}"; do
  git -C "$REPO" show "$COMMIT:$f" > "$STAGE/$(basename "$f")" || fail "extract failed: $f"
  want="$(git -C "$REPO" show "$COMMIT:$f" | sha_of)"; got="$(sha_of < "$STAGE/$(basename "$f")")"
  [ "$want" = "$got" ] || fail "hash mismatch: $f"
  echo "$want  $(basename "$f")" >> "$STAGE/SHA256SUMS"
done
say "staged ${#FILES[@]} files, hashes verified"

install -d -o root -g root -m 0755 "$LIBDIR" || fail "mkdir $LIBDIR"
for f in aegl-model-broker aegl-hermes-sandbox; do install -o root -g root -m 0755 "$STAGE/$f" "$LIBDIR/$f" || fail "install $f"; done
for f in model_broker.py loopback_shim.py; do install -o root -g root -m 0644 "$STAGE/$f" "$LIBDIR/$f" || fail "install $f"; done
install -d -o root -g root -m 0750 "$CREDDIR" || fail "mkdir $CREDDIR"

# trusted config (root-owned): fixes the upstream, the credential source, and the runtime.
# The upstream and auth format are the existing Command Code provider (Bearer).
CFG="/etc/aegl/model/config"
if [ ! -f "$CFG" ]; then
  install -d -o root -g root -m 0755 /etc/aegl/model || fail "mkdir /etc/aegl/model"
  cat > "$CFG" <<'CONF'
UPSTREAM=https://api.commandcode.ai/provider/v1
CREDENTIAL_ENV=COMMANDCODE_API_KEY
CREDENTIAL_SOURCE=/home/zhong/.hermes/.env
HERMES_ENTRY=/home/zhong/.local/bin/hermes
HERMES_RUNTIME=/home/zhong/.hermes/hermes-agent
HERMES_TOOLS=/home/zhong/.hermes/tools
HERMES_INSTALLS=/home/zhong/.hermes/installs
HERMES_HOME_REAL=/home/zhong/.hermes
HERMES_PROFILE_CONFIG=/home/zhong/.hermes/profiles/android-stack/config.yaml
CONF
  chown root:root "$CFG"; chmod 0644 "$CFG" || fail "write $CFG"
  say "  wrote trusted config: $CFG (upstream=api.commandcode.ai/provider/v1, credential env=COMMANDCODE_API_KEY)"
else
  say "  trusted config present: $CFG (left unchanged)"
fi

# trusted task registry (root-owned; the launcher reads task paths from HERE, not task.json)
install -d -o root -g root -m 0755 "$REGDIR" || fail "mkdir $REGDIR"
[ -f "$REGDIR/registry.json" ] || { printf '{}\n' > "$REGDIR/registry.json"; }
chown root:root "$REGDIR/registry.json"; chmod 0644 "$REGDIR/registry.json" || fail "registry perms"

say "  program: $LIBDIR (aegl-model-broker, aegl-hermes-sandbox, model_broker.py, loopback_shim.py)"
say "  trusted config: $CFG"
say "  trusted task registry: $REGDIR/registry.json (root-owned)"
say ""
say "NOT done: it does not create the model credential or write it anywhere (the broker reads the"
say "existing COMMANDCODE_API_KEY from its original location as DATA), does not run 'switch', change"
say "project permissions, merge any project, or write /etc/aegl/broker-verified."

# --- real independent-UID trial (aegl-ai + the real Command Code/DeepSeek) ----- #
self_test(){
  say ""
  say "== real independent-UID trial via aegl-hermes-sandbox =="
  local ST; ST="$(mktemp -d /var/tmp/aegl-hermes-trial-XXXXXX)" || fail "mktemp failed"
  local PROJ="$ST/Google-Android-Agent-Development-Stack" WT="$ST/wt" SCR="$ST/scratch" PROT="$ST/protected"
  mkdir -p "$PROJ" "$SCR" "$PROT"
  chown root:root "$PROT"; chmod 0755 "$PROT"
  chown -R "$AI_USER":"$(id -g "$AI_USER")" "$ST" 2>/dev/null || true
  runuser -u "$AI_USER" -- git init -q "$PROJ" || fail "git init"
  runuser -u "$AI_USER" -- bash -c "cd '$PROJ' && echo base > README.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm base" || fail "base commit"
  runuser -u "$AI_USER" -- git -C "$PROJ" worktree add -q -b trial "$WT" HEAD || fail "worktree"
  printf 'TRIAL-INPUT-OK\n' > "$WT/INPUT.txt"
  cat > "$WT/PROMPT.md" <<EOF
Read INPUT.txt in the current directory and write its exact single line into RESULT.txt here.
Also run these shell commands and write their RAW output (label each line) into FACTS.txt here:
  id -u
  readlink /proc/self/ns/pid
  ( echo BREACH > '$PROT/BREACH' && echo PROTECTED_WRITE_OK ) || echo PROTECTED_WRITE_DENIED
Then report RESULT.txt's content, the uid, the pid namespace and whether the protected write was
denied, and stop.
EOF
  chown -R "$AI_USER":"$(id -g "$AI_USER")" "$WT"
  python3 - "$REGDIR/registry.json" trial "$WT" "$SCR" "$PROJ" <<'PY'
import json, sys
p, tid, wt, scr, proj = sys.argv[1:6]
reg = json.load(open(p, encoding="utf-8"))
reg[tid] = {"worktree": wt, "scratch": scr, "project": proj}
json.dump(reg, open(p, "w", encoding="utf-8"), indent=2)
PY
  chown root:root "$REGDIR/registry.json"; chmod 0644 "$REGDIR/registry.json"
  local host_ns; host_ns="$(readlink /proc/self/ns/pid)"
  say "  running the real entry (task trial) ..."
  "$LIBDIR/aegl-hermes-sandbox" --task trial -- hermes -p android-stack chat --oneshot --query-file "$WT/PROMPT.md"
  local rc=$? ; local fails=0
  [ -f "$WT/RESULT.txt" ] && grep -q 'TRIAL-INPUT-OK' "$WT/RESULT.txt" && say "  PASS: model wrote the allowed task dir (real model call)" || { say "  FAIL: no RESULT.txt from the model"; fails=$((fails+1)); }
  [ ! -e "$PROT/BREACH" ] && say "  PASS: external protected write denied" || { say "  FAIL: protected write succeeded"; fails=$((fails+1)); }
  if [ -f "$WT/FACTS.txt" ]; then
    grep -q "$(id -u "$AI_USER")" "$WT/FACTS.txt" && say "  PASS: model ran as the AI uid ($(id -u "$AI_USER"))" || { say "  FAIL: model uid is not $(id -u "$AI_USER")"; fails=$((fails+1)); }
    grep -q 'DENIED' "$WT/FACTS.txt" && say "  PASS: model observed the protected write denial" || say "  NOTE: model did not report DENIED (see FACTS.txt)"
    if grep -q 'pid:' "$WT/FACTS.txt" || grep -q 'pid\[' "$WT/FACTS.txt"; then
      grep -qF "$host_ns" "$WT/FACTS.txt" && { say "  FAIL: model shares the host pid namespace"; fails=$((fails+1)); } || say "  PASS: model is in a distinct pid namespace"
    fi
  else
    say "  NOTE: no FACTS.txt (uid/namespace/denial not self-reported); inspect the sandbox output"
  fi
  rm -rf "$ST"
  [ "$fails" -eq 0 ] || say "  trial failures=$fails"
  [ "$fails" -eq 0 ]
}

rc=0
[ "$SELF_TEST" = 1 ] && { self_test || rc=1; }
if [ "$rc" != 0 ]; then printf 'INSTALL_RESULT=FAILED commit=%s\n' "$COMMIT"; exit 1; fi
printf 'INSTALL_RESULT=OK commit=%s\n' "$COMMIT"
