#!/usr/bin/env bash
# install-broker.sh — idempotent, reviewable installer for the AEGL promotion broker.
#
# Scope: the broker program + its identities + root-owned service ONLY. It does NOT
# run `switch`, does NOT change project permissions, does NOT merge any project and
# does NOT write /etc/aegl/broker-verified.
#
#   sudo install-broker.sh --commit <full-40-hex-commit>            # install
#   sudo install-broker.sh --commit <full-40-hex-commit> --self-test  # install + bounded
#                                                                     # independent-UID acceptance
#
# Every installed file is extracted from the pinned commit via `git show` and its
# sha256 is verified. Requires root.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AEGL_ROOT="$(cd "$SELF_DIR/.." && pwd)"

LIBDIR="/usr/local/lib/aegl-promote"
RUNDIR="/run/aegl-promote"
REGDIR="/var/lib/aegl-promote"
UNIT="/etc/systemd/system/aegl-promote-broker.service"
BROKER_USER="aegl-promote"; BROKER_GROUP="aegl-broker"
AI_USER="aegl-ai";          AI_GROUP="aegl-ai"
FILES=(bin/aegl-promote-broker recovery/promotion_broker.py recovery/promotion_core.py)

say(){ printf '%s\n' "$*"; }
die(){ printf 'INSTALL_BLOCKED: %s\n' "$*" >&2; exit 1; }

COMMIT=""; SELF_TEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --commit) COMMIT="${2:-}"; shift 2 ;;
    --self-test) SELF_TEST=1; shift ;;
    *) die "usage: install-broker.sh --commit <40-hex> [--self-test]" ;;
  esac
done
[ "$(id -u)" = 0 ] || die "must run as root"
case "$COMMIT" in
  [0-9a-f][0-9a-f]*) : ;;
  *) die "--commit must be a full 40-hex commit id" ;;
esac
[ "${#COMMIT}" -eq 40 ] || die "--commit must be a full 40-hex commit id (got ${#COMMIT} chars)"
git -C "$AEGL_ROOT" cat-file -e "$COMMIT^{commit}" 2>/dev/null || die "commit not found in $AEGL_ROOT: $COMMIT"

sha_of(){ sha256sum | awk '{print $1}'; }

say "AEGL promotion broker install   commit=$COMMIT"

# --- identities (idempotent) ------------------------------------------------- #
getent group "$BROKER_GROUP" >/dev/null || groupadd --system "$BROKER_GROUP"
getent group "$AI_GROUP"     >/dev/null || groupadd --system "$AI_GROUP"
id "$BROKER_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin --gid "$BROKER_GROUP" "$BROKER_USER"
id "$AI_USER"     >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin --gid "$AI_GROUP" "$AI_USER"
usermod -aG "$BROKER_GROUP" "$AI_USER"      # the AI identity may connect to the socket
say "  identities: $BROKER_USER:$BROKER_GROUP (broker), $AI_USER:$AI_GROUP (AI requester)"

# --- program (from the pinned commit; verify hashes) ------------------------- #
install -d -o root -g root -m 0755 "$LIBDIR"
for f in "${FILES[@]}"; do
  base="$(basename "$f")"
  want="$(git -C "$AEGL_ROOT" show "$COMMIT:$f" | sha_of)"
  tmp="$(mktemp)"; git -C "$AEGL_ROOT" show "$COMMIT:$f" > "$tmp"
  got="$(sha_of < "$tmp")"
  [ "$want" = "$got" ] || die "hash mismatch extracting $f from $COMMIT"
  mode=0644; case "$base" in aegl-*) mode=0755 ;; esac
  install -o root -g root -m "$mode" "$tmp" "$LIBDIR/$base"
  rm -f "$tmp"
  say "  installed $LIBDIR/$base sha256=$want"
done
# guard against a stale extra module dir layout
[ -x "$LIBDIR/aegl-promote-broker" ] || die "launcher not executable"

# --- socket dir + registry dir (idempotent) ---------------------------------- #
install -d -o "$BROKER_USER" -g "$BROKER_GROUP" -m 2770 "$RUNDIR"
install -d -o "$BROKER_USER" -g "$BROKER_GROUP" -m 0700 "$REGDIR"

# --- systemd unit (root-owned; explicit registry + allowlists) --------------- #
unit_tmp="$(mktemp)"
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
Environment=PROJECTS_ROOT=$AEGL_ROOT/..
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
  install -o root -g root -m 0644 "$unit_tmp" "$UNIT"; say "  wrote unit: $UNIT"
fi
rm -f "$unit_tmp"
systemctl daemon-reload
systemctl enable --now aegl-promote-broker >/dev/null 2>&1 || say "  NOTE: systemctl enable/start reported non-zero (check the unit)"
say "  service: systemctl status aegl-promote-broker"

say ""
say "NOT done by this installer: project permission migration ('switch'), any project merge, and"
say "the /etc/aegl/broker-verified marker (root writes it manually after the acceptance below)."

# --- bounded independent-UID acceptance -------------------------------------- #
self_test(){
  say ""
  say "== independent-UID acceptance (throwaway repo) =="
  local ST; ST="$(mktemp -d /var/tmp/aegl-uidtest-XXXXXX)" || die "mktemp failed"
  chmod 0755 "$ST"
  local PROOT="$ST/projects" REG="$ST/registry" SOCK="$ST/broker.sock"
  mkdir -p "$PROOT"
  # a throwaway allowed project, owned by the broker identity (it materializes objects there)
  git -C "$PROOT" init -q
  mkdir -p "$PROOT/Google-Android-Agent-Development-Stack"
  git -C "$PROOT/Google-Android-Agent-Development-Stack" init -q
  ( cd "$PROOT/Google-Android-Agent-Development-Stack" && echo base > README.md && git add -A \
      && git -c user.email=t@t -c user.name=t commit -qm base )
  chown -R "$BROKER_USER":"$BROKER_GROUP" "$PROOT" "$ST"
  chmod 0775 "$ST" "$PROOT"
  BASE="$(git -C "$PROOT/Google-Android-Agent-Development-Stack" rev-parse HEAD)"
  # a candidate worktree owned by the broker identity
  local WT="$ST/wt"; git -C "$PROOT/Google-Android-Agent-Development-Stack" worktree add -q -b cand "$WT" HEAD
  ( cd "$WT" && echo hello > feature.txt )
  chown -R "$BROKER_USER":"$BROKER_GROUP" "$WT" 2>/dev/null || true

  runuser -u "$BROKER_USER" -- env AEGL_BROKER_SOCKET="$SOCK" AEGL_BROKER_REGISTRY_DIR="$REG" \
    PROJECTS_ROOT="$PROOT" AEGL_PROJECT_ALLOWLIST="Google-Android-Agent-Development-Stack" \
    AEGL_BROKER_ALLOW_REQUESTERS="$AI_USER" AEGL_BROKER_ALLOW_RECORDERS=root \
    "$LIBDIR/aegl-promote-broker" serve >"$ST/broker.log" 2>&1 &
  local BPID=$!
  local i; for i in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
  [ -S "$SOCK" ] || { say "  FAIL: broker did not start as $BROKER_USER"; cat "$ST/broker.log"; kill "$BPID" 2>/dev/null; return 1; }

  local fails=0
  ask(){ runuser -u "$1" -- env AEGL_BROKER_SOCKET="$SOCK" "$LIBDIR/aegl-promote-broker" client --request "$2" 2>/dev/null; }
  expect(){ # <label> <user> <request> <decision>
    local got; got="$(ask "$2" "$3" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("decision",""))
except Exception: print("PARSE_ERROR")' 2>/dev/null)"
    if [ "$got" = "$4" ]; then say "  PASS: $1"; else say "  FAIL: $1 (got $got want $4)"; fails=$((fails+1)); fi
  }

  # the AI identity may NOT register/record (it is not the trusted recorder)
  expect "AI cannot register (recorder-only)" "$AI_USER" "{\"op\":\"register\",\"task_id\":\"u1\",\"project\":\"$PROOT/Google-Android-Agent-Development-Stack\",\"base\":\"$BASE\",\"worktree\":\"$WT\",\"branch\":\"cand\"}" REJECTED
  # root (trusted control) registers + records
  expect "root registers" root "{\"op\":\"register\",\"task_id\":\"u1\",\"project\":\"$PROOT/Google-Android-Agent-Development-Stack\",\"base\":\"$BASE\",\"worktree\":\"$WT\",\"branch\":\"cand\"}" REGISTERED
  expect "root records (verify PASS)" root "{\"op\":\"record\",\"task_id\":\"u1\",\"verify_result\":\"PASS\"}" RECORDED
  # the AI identity may request promote for the approved task
  expect "AI promotes the approved task" "$AI_USER" "{\"op\":\"promote\",\"task_id\":\"u1\"}" APPLIED
  expect "AI cannot record (recorder-only)" "$AI_USER" "{\"op\":\"record\",\"task_id\":\"u1\",\"verify_result\":\"PASS\"}" REJECTED

  kill "$BPID" 2>/dev/null; wait "$BPID" 2>/dev/null
  say "  independent-UID acceptance failures=$fails"
  rm -rf "$ST"
  [ "$fails" -eq 0 ]
}

rc=0
[ "$SELF_TEST" = 1 ] && { self_test || rc=1; }
say ""
say "INSTALL_RESULT=$([ "$rc" = 0 ] && echo OK || echo PARTIAL) commit=$COMMIT"
exit "$rc"
