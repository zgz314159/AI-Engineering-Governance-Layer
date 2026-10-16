#!/usr/bin/env bash
# install-broker.sh — idempotent, reviewable installer for the AEGL promotion broker.
#
# Supports the real delivery form (piped to `bash -s`, where $BASH_SOURCE is absent):
# every input is explicit — --repo, --projects-root and a full --commit. Nothing is
# derived from the script's own location. All inputs and required files are validated
# BEFORE any host change; any extraction/install/service/acceptance failure returns
# non-zero and never prints INSTALL_RESULT=OK.
#
# Scope: the broker program + its identities + root-owned service ONLY. It does NOT run
# `switch`, change project permissions, merge any project, or write /etc/aegl/broker-verified.
#
#   sudo bash install-broker.sh --repo <AEGL> --projects-root <Projects> \
#        --commit <full-40-hex> [--business-root <AppProjects>] [--self-test]
set -uo pipefail

REPO=""; PROJECTS_ROOT=""; BUSINESS_ROOT=""; COMMIT=""; SELF_TEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --projects-root) PROJECTS_ROOT="${2:-}"; shift 2 ;;
    --business-root) BUSINESS_ROOT="${2:-}"; shift 2 ;;
    --commit) COMMIT="${2:-}"; shift 2 ;;
    --self-test) SELF_TEST=1; shift ;;
    *) printf 'INSTALL_ERROR: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
done

LIBDIR="/usr/local/lib/aegl-promote"
RUNDIR="/run/aegl-promote"
REGDIR="/var/lib/aegl-promote"
UNIT="/etc/systemd/system/aegl-promote-broker.service"
BROKER_USER="aegl-promote"; BROKER_GROUP="aegl-broker"
AI_USER="aegl-ai";          AI_GROUP="aegl-ai"
FILES=(bin/aegl-promote-broker recovery/promotion_broker.py recovery/promotion_core.py)

say(){ printf '%s\n' "$*"; }
fail(){ printf 'INSTALL_ERROR: %s\n' "$*" >&2; exit 1; }
sha_of(){ sha256sum | awk '{print $1}'; }

# --- validate EVERYTHING before any host change ------------------------------ #
[ "$(id -u)" = 0 ] || fail "must run as root"
[ -n "$REPO" ] || fail "--repo is required"
[ -n "$PROJECTS_ROOT" ] || fail "--projects-root is required"
[ -n "$COMMIT" ] || fail "--commit is required"
[ -d "$REPO/.git" ] || fail "--repo is not a git repository: $REPO"
[ -d "$PROJECTS_ROOT" ] || fail "--projects-root is not a directory: $PROJECTS_ROOT"
# Business root: external AppProjects sibling of Projects (not $HOME itself).
# Directory may be absent until first business-project migrate; unit still carries the path.
_PROJ_PARENT="$(cd "$PROJECTS_ROOT/.." && pwd)" || fail "--projects-root parent unreadable"
if [ -z "$BUSINESS_ROOT" ]; then
  BUSINESS_ROOT="$_PROJ_PARENT/AppProjects"
else
  _br_parent="$(dirname "$BUSINESS_ROOT")"
  _br_base="$(basename "$BUSINESS_ROOT")"
  [ -d "$_br_parent" ] || fail "--business-root parent missing: $_br_parent"
  BUSINESS_ROOT="$(cd "$_br_parent" && pwd)/$_br_base"
fi
case "$BUSINESS_ROOT" in
  "$PROJECTS_ROOT"|"$PROJECTS_ROOT"/*) fail "--business-root must not be inside --projects-root" ;;
esac
[ "$BUSINESS_ROOT" != "$_PROJ_PARENT" ] \
  || fail "--business-root must not be the projects parent itself (refusing home-wide allow root)"
case "$COMMIT" in
  [0-9a-f][0-9a-f]*) : ;;
  *) fail "--commit must be a full 40-hex commit id" ;;
esac
[ "${#COMMIT}" -eq 40 ] || fail "--commit must be a full 40-hex commit id (got ${#COMMIT} chars)"
git -C "$REPO" cat-file -e "$COMMIT^{commit}" 2>/dev/null || fail "commit not found in $REPO: $COMMIT"
for f in "${FILES[@]}"; do
  git -C "$REPO" cat-file -e "$COMMIT:$f" 2>/dev/null || fail "required file missing in commit: $f"
done

say "AEGL promotion broker install   repo=$REPO projects_root=$PROJECTS_ROOT business_root=$BUSINESS_ROOT commit=$COMMIT"

# --- stage the files (verify hashes) BEFORE touching the host ---------------- #
STAGE="$(mktemp -d)" || fail "mktemp failed"
trap 'rm -rf "$STAGE"' EXIT
for f in "${FILES[@]}"; do
  git -C "$REPO" show "$COMMIT:$f" > "$STAGE/$(basename "$f")" || fail "extract failed: $f"
  want="$(git -C "$REPO" show "$COMMIT:$f" | sha_of)"
  got="$(sha_of < "$STAGE/$(basename "$f")")"
  [ "$want" = "$got" ] || fail "hash mismatch extracting $f from $COMMIT"
  echo "$want  $(basename "$f")" >> "$STAGE/SHA256SUMS"
done
say "  staged ${#FILES[@]} files, all hashes verified"

# --- identities (idempotent) ------------------------------------------------- #
getent group "$BROKER_GROUP" >/dev/null || groupadd --system "$BROKER_GROUP" || fail "groupadd $BROKER_GROUP"
getent group "$AI_GROUP"     >/dev/null || groupadd --system "$AI_GROUP" || fail "groupadd $AI_GROUP"
id "$BROKER_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin --gid "$BROKER_GROUP" "$BROKER_USER" || fail "useradd $BROKER_USER"
id "$AI_USER"     >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin --gid "$AI_GROUP" "$AI_USER" || fail "useradd $AI_USER"
usermod -aG "$BROKER_GROUP" "$AI_USER" || fail "usermod $AI_USER"
say "  identities ok: $BROKER_USER:$BROKER_GROUP (broker), $AI_USER:$AI_GROUP (AI requester)"

# --- program + dirs + unit --------------------------------------------------- #
install -d -o root -g root -m 0755 "$LIBDIR" || fail "mkdir $LIBDIR"
install -o root -g root -m 0755 "$STAGE/aegl-promote-broker" "$LIBDIR/aegl-promote-broker" || fail "install launcher"
install -o root -g root -m 0644 "$STAGE/promotion_broker.py" "$LIBDIR/promotion_broker.py" || fail "install broker module"
install -o root -g root -m 0644 "$STAGE/promotion_core.py" "$LIBDIR/promotion_core.py" || fail "install core module"
install -d -o "$BROKER_USER" -g "$BROKER_GROUP" -m 2770 "$RUNDIR" || fail "mkdir $RUNDIR"
install -d -o "$BROKER_USER" -g "$BROKER_GROUP" -m 0700 "$REGDIR" || fail "mkdir $REGDIR"

unit_tmp="$(mktemp)"; trap 'rm -rf "$STAGE" "$unit_tmp"' EXIT
cat > "$unit_tmp" <<UNIT
[Unit]
Description=AEGL trusted promotion broker
After=local-fs.target

[Service]
Type=simple
User=$BROKER_USER
Group=$BROKER_GROUP
RuntimeDirectory=aegl-promote
RuntimeDirectoryMode=2770
Environment=AEGL_BROKER_SOCKET=$RUNDIR/broker.sock
Environment=AEGL_BROKER_REGISTRY_DIR=$REGDIR
Environment=PROJECTS_ROOT=$PROJECTS_ROOT
Environment=AEGL_BUSINESS_ROOT=$BUSINESS_ROOT
Environment=AEGL_PROJECT_ALLOWLIST=Google-Android-Agent-Development-Stack,KeepLab-Relay,AI-Engineering-Governance-Layer
Environment=AEGL_BROKER_ALLOW_REQUESTERS=$AI_USER
Environment=AEGL_BROKER_ALLOW_RECORDERS=root
ExecStart=$LIBDIR/aegl-promote-broker serve
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
if [ -f "$UNIT" ] && cmp -s "$unit_tmp" "$UNIT"; then
  say "  unit unchanged: $UNIT"
else
  install -o root -g root -m 0644 "$unit_tmp" "$UNIT" || fail "install unit"
  say "  wrote unit: $UNIT"
fi
systemctl daemon-reload || fail "systemctl daemon-reload"
# Ensure enabled, then always restart so the running process loads the files just
# installed from --commit. enable --now alone is insufficient when the unit was
# already active (it would keep the old program in memory).
systemctl enable aegl-promote-broker >/dev/null 2>&1 || fail "systemctl enable aegl-promote-broker"
say "  restarting aegl-promote-broker to load installed program commit=$COMMIT"
systemctl restart aegl-promote-broker || fail "systemctl restart aegl-promote-broker"
# Contained wait: active state, then socket ready. Identity/allowlists unchanged.
_i=0
while [ "$_i" -lt 50 ]; do
  systemctl is-active --quiet aegl-promote-broker && break
  sleep 0.1
  _i=$((_i + 1))
done
systemctl is-active --quiet aegl-promote-broker \
  || fail "service aegl-promote-broker is not active after restart"
_i=0
while [ "$_i" -lt 50 ]; do
  [ -S "$RUNDIR/broker.sock" ] && break
  sleep 0.1
  _i=$((_i + 1))
done
[ -S "$RUNDIR/broker.sock" ] \
  || fail "broker socket not ready after restart: $RUNDIR/broker.sock"
say "  service active; socket ready: $RUNDIR/broker.sock"

# --- bounded independent-UID acceptance -------------------------------------- #
self_test(){
  say ""
  say "== independent-UID acceptance (throwaway repo; official projects untouched) =="
  local ST; ST="$(mktemp -d /var/tmp/aegl-uidtest-XXXXXX)" || fail "mktemp failed"
  local BPID=""
  # always clean up the test process + temp dir, on success or failure
  trap 'if [ -n "$BPID" ]; then kill "$BPID" 2>/dev/null; wait "$BPID" 2>/dev/null; fi; chmod -R u+w "$ST" 2>/dev/null; rm -rf "$ST"' RETURN
  chmod 0755 "$ST"
  local PROOT="$ST/projects" REG="$ST/registry" SOCK="$ST/broker.sock" HB="$ST/home"
  mkdir -p "$PROOT" "$HB"
  chown "$BROKER_USER":"$BROKER_GROUP" "$ST" "$PROOT" "$HB"
  # git runs AS the repo-owning identity (never safe.directory=*; never as root)
  bgit(){ runuser -u "$BROKER_USER" -- env HOME="$HB" git "$@"; }
  local APP="$PROOT/Google-Android-Agent-Development-Stack"
  mkdir -p "$APP"; chown "$BROKER_USER":"$BROKER_GROUP" "$APP"
  bgit -C "$APP" init -q || { say "  FAIL: init as $BROKER_USER"; return 1; }
  ( cd "$APP" && echo base > README.md )
  bgit -C "$APP" add -A
  bgit -C "$APP" -c user.email=t@t -c user.name=t commit -qm base
  local BASE; BASE="$(bgit -C "$APP" rev-parse HEAD)"
  local WT="$ST/wt"
  bgit -C "$APP" worktree add -q -b cand "$WT" HEAD
  echo hello > "$WT/feature.txt"

  timeout 150 runuser -u "$BROKER_USER" -- env \
    AEGL_BROKER_SOCKET="$SOCK" AEGL_BROKER_REGISTRY_DIR="$REG" PROJECTS_ROOT="$PROOT" \
    AEGL_PROJECT_ALLOWLIST="Google-Android-Agent-Development-Stack" \
    AEGL_BROKER_ALLOW_REQUESTERS="$AI_USER" AEGL_BROKER_ALLOW_RECORDERS=root \
    "$LIBDIR/aegl-promote-broker" serve >"$ST/broker.log" 2>&1 &
  BPID=$!
  local i; for i in $(seq 1 60); do [ -S "$SOCK" ] && break; sleep 0.1; done
  [ -S "$SOCK" ] || { say "  FAIL: broker did not start as $BROKER_USER"; cat "$ST/broker.log"; return 1; }

  local fails=0
  ask(){ runuser -u "$1" -- env AEGL_BROKER_SOCKET="$SOCK" "$LIBDIR/aegl-promote-broker" client --request "$2" 2>/dev/null; }
  expect(){ local got; got="$(ask "$2" "$3" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("decision",""))
except Exception: print("PARSE_ERROR")' 2>/dev/null)"
    if [ "$got" = "$4" ]; then say "  PASS: $1"; else say "  FAIL: $1 (got $got want $4)"; fails=$((fails+1)); fi; }

  # Candidate tip must be a real commit (full-stack freeze); commit as repo owner.
  chown -R "$BROKER_USER":"$BROKER_GROUP" "$WT"
  bgit -C "$WT" add -A
  bgit -C "$WT" -c user.email=t@t -c user.name=t commit -qm cand
  bgit -C "$APP" branch -M master
  expect "AI identity cannot register (recorder-only)" "$AI_USER" \
    "{\"op\":\"register\",\"task_id\":\"u1\",\"project\":\"$APP\",\"base\":\"$BASE\",\"worktree\":\"$WT\",\"branch\":\"cand\",\"target_ref\":\"refs/heads/main\"}" REJECTED
  expect "root registers" root \
    "{\"op\":\"register\",\"task_id\":\"u1\",\"project\":\"$APP\",\"base\":\"$BASE\",\"worktree\":\"$WT\",\"branch\":\"cand\",\"target_ref\":\"refs/heads/main\"}" REGISTERED
  expect "root records (verify PASS)" root \
    "{\"op\":\"record\",\"task_id\":\"u1\",\"verify_result\":\"PASS\"}" RECORDED
  expect "AI identity promotes the approved task" "$AI_USER" \
    "{\"op\":\"promote\",\"task_id\":\"u1\"}" APPLIED
  expect "AI identity cannot record" "$AI_USER" \
    "{\"op\":\"record\",\"task_id\":\"u1\",\"verify_result\":\"PASS\"}" REJECTED

  kill "$BPID" 2>/dev/null; wait "$BPID" 2>/dev/null; BPID=""
  say "  independent-UID acceptance failures=$fails"
  [ "$fails" -eq 0 ]
}

say ""
say "NOT done by this installer: project permission migration ('switch'), any project merge, and"
say "the /etc/aegl/broker-verified marker (root writes it manually after the acceptance)."

rc=0
if [ "$SELF_TEST" = 1 ]; then self_test || rc=1; fi
if [ "$rc" != 0 ]; then printf 'INSTALL_RESULT=FAILED commit=%s\n' "$COMMIT"; exit 1; fi
printf 'INSTALL_RESULT=OK commit=%s\n' "$COMMIT"
