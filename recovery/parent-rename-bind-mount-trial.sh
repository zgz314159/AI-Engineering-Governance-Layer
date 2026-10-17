#!/usr/bin/env bash
# parent-rename-bind-mount-trial.sh — ONE limited private-mountns experiment.
#
# Verifies RW bind-mounts on project + parent entrypoints block non-privileged
# rename / renameat2(EXCHANGE), while aegl-promote can still CAS + body-sync.
# Does NOT deploy to formal Projects/AppProjects. No mount unit / fstab / chattr.
#
# --commit pins the formal AEGL refs/heads/main baseline only. This script file
# is NOT claimed to be contained in that Git commit.
#
# Delivery: copy to root-only temp, verify sha256, then run (never sudo this
# user-writable path directly). --commit = formal baseline pin only.
set -euo pipefail

TIP_EXPECT=""
FORMAL_AEGL="/home/zhong/Projects/AI-Engineering-Governance-Layer"
OP_USER="zhong"
AI_USER="aegl-ai"
BROKER_USER="aegl-promote"
HUMAN_GROUP="aegl-ro"
MODE="outer"   # outer | inner

while [ $# -gt 0 ]; do
  case "$1" in
    --commit) TIP_EXPECT="${2:-}"; shift 2 ;;
    --aegl) FORMAL_AEGL="${2:-}"; shift 2 ;;
    --inner) MODE="inner"; shift ;;
    *) printf 'TRIAL_ERROR: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
done

say(){ printf '%s\n' "$*"; }
fail(){ printf 'TRIAL_FAIL: %s\n' "$*" >&2; exit 1; }
stop(){ printf 'STOP_AT=%s\n' "$1" >&2; shift; printf 'TRIAL_ERROR: %s\n' "$*" >&2; exit 1; }

# Probe result kinds (global for callers; probes never toggle set -e).
# denied | success | path_missing | timeout | unsupported | error
PROBE_KIND=""
PROBE_RC=""
PROBE_LINE=""

log(){
  local out="${OUT:-}"
  if [ -n "$out" ]; then
    printf '%s\n' "$*" | tee -a "$out"
  else
    printf '%s\n' "$*"
  fi
}

# Exact mountpoint check (not findmnt -T filesystem lookup).
assert_exact_mountpoint(){
  local p="$1" mp
  mp="$(findmnt -n -o TARGET --mountpoint "$p" 2>/dev/null || true)"
  [ "$mp" = "$p" ] || fail "not an exact mountpoint: $p (findmnt got '${mp:-empty}')"
}

# --------------------------------------------------------------------------- #
# rename probe — if/else only; does not change caller's errexit
# python exit: 0 success, 1 denied, 11 path_missing, 12 timeout, 13 unsupported, 99 error
# --------------------------------------------------------------------------- #
_probe_python_rename(){
  # args via env: PROBE_USER PROBE_OP(src/dst or exchange) SRC DST LABEL
  # exit: 0 success, 1 denied(EBUSY/EACCES/EPERM only), 11 path_missing,
  #       13 unsupported(ENOSYS/EOPNOTSUPP), 99 error(unexpected errno/exception)
  runuser -u "$PROBE_USER" -- env \
    PROBE_USER="$PROBE_USER" PROBE_OP="$PROBE_OP" \
    SRC="$SRC" DST="$DST" LABEL="$LABEL" \
    python3 - <<'PY'
import errno, os, sys, ctypes, ctypes.util

user = os.environ["PROBE_USER"]
op = os.environ["PROBE_OP"]
src = os.environ["SRC"]
dst = os.environ["DST"]
label = os.environ["LABEL"]

# Strict: only these count as protection denial.
DENIED_ERRNOS = {errno.EBUSY, errno.EACCES, errno.EPERM}
UNSUPPORTED_ERRNOS = {errno.ENOSYS}
if hasattr(errno, "EOPNOTSUPP"):
    UNSUPPORTED_ERRNOS.add(errno.EOPNOTSUPP)

def emit(kind, rc, errno_v, msg=""):
    ename = errno.errorcode.get(errno_v, "?") if errno_v else "0"
    print(f"PROBE {label} user={user} op={op} kind={kind} rc={rc} errno={errno_v}({ename}) src={src} dst={dst}{msg}")

def classify_errno(e):
    """Return (kind, exit_code) for a failed rename/renameat2."""
    if e == errno.ENOENT:
        return "path_missing", 11
    if e in UNSUPPORTED_ERRNOS:
        return "unsupported", 13
    if e in DENIED_ERRNOS:
        return "denied", 1
    # ENOENT already handled; ENOTDIR/EIO/ENOMEM/EINVAL/EXDEV/… → error
    return "error", 99

if not os.path.lexists(src):
    emit("path_missing", -1, errno.ENOENT, " detail=src_missing")
    sys.exit(11)
if op == "exchange" and not os.path.lexists(dst):
    emit("path_missing", -1, errno.ENOENT, " detail=dst_missing")
    sys.exit(11)

if op == "rename":
    try:
        os.rename(src, dst)
        emit("success", 0, 0)
        sys.exit(0)
    except OSError as e:
        kind, code = classify_errno(e.errno)
        emit(kind, -1, e.errno)
        sys.exit(code)
    except Exception as e:
        emit("error", -1, 0, f" detail={e!r}")
        sys.exit(99)

if op == "exchange":
    RENAME_EXCHANGE = 2
    AT_FDCWD = -100
    libname = ctypes.util.find_library("c")
    if not libname:
        emit("unsupported", -1, errno.ENOSYS, " detail=no_libc")
        sys.exit(13)
    libc = ctypes.CDLL(libname, use_errno=True)
    if not hasattr(libc, "renameat2"):
        emit("unsupported", -1, errno.ENOSYS, " detail=no_renameat2_symbol")
        sys.exit(13)
    libc.renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    libc.renameat2.restype = ctypes.c_int
    ctypes.set_errno(0)
    r = libc.renameat2(AT_FDCWD, src.encode(), AT_FDCWD, dst.encode(), RENAME_EXCHANGE)
    if r == 0:
        emit("success", 0, 0)
        sys.exit(0)
    e = ctypes.get_errno()
    kind, code = classify_errno(e)
    emit(kind, -1, e)
    sys.exit(code)

emit("error", -1, 0, " detail=bad_op")
sys.exit(99)
PY
}

# Sets PROBE_KIND / PROBE_RC / PROBE_LINE. Never toggles set -e.
probe_rename(){
  local user="$1" src="$2" dst="$3" label="$4"
  PROBE_USER="$user" PROBE_OP="rename" SRC="$src" DST="$dst" LABEL="$label"
  PROBE_LINE=""
  PROBE_RC=0
  PROBE_KIND=""
  if PROBE_LINE="$(_probe_python_rename)"; then
    PROBE_RC=0
  else
    PROBE_RC=$?
  fi
  log "$PROBE_LINE"
  case "$PROBE_RC" in
    0)  PROBE_KIND=success ;;
    1)  PROBE_KIND=denied ;;
    11) PROBE_KIND=path_missing ;;
    12) PROBE_KIND=timeout ;;
    13) PROBE_KIND=unsupported ;;
    *)  PROBE_KIND=error ;;
  esac
}

probe_exchange(){
  local user="$1" src="$2" dst="$3" label="$4"
  PROBE_USER="$user" PROBE_OP="exchange" SRC="$src" DST="$dst" LABEL="$label"
  PROBE_LINE=""
  PROBE_RC=0
  PROBE_KIND=""
  if PROBE_LINE="$(_probe_python_rename)"; then
    PROBE_RC=0
  else
    PROBE_RC=$?
  fi
  log "$PROBE_LINE"
  case "$PROBE_RC" in
    0)  PROBE_KIND=success ;;
    1)  PROBE_KIND=denied ;;
    11) PROBE_KIND=path_missing ;;
    12) PROBE_KIND=timeout ;;
    13) PROBE_KIND=unsupported ;;
    *)  PROBE_KIND=error ;;
  esac
}

expect_rename_ok(){
  local user="$1" src="$2" dst="$3" label="$4"
  probe_rename "$user" "$src" "$dst" "$label"
  if [ "$PROBE_KIND" = success ]; then
    return 0
  fi
  fail "$label: expected rename success for $user (kind=$PROBE_KIND rc=$PROBE_RC) — control invalid"
}

expect_exchange_ok(){
  local user="$1" src="$2" dst="$3" label="$4"
  probe_exchange "$user" "$src" "$dst" "$label"
  if [ "$PROBE_KIND" = success ]; then
    return 0
  fi
  fail "$label: expected RENAME_EXCHANGE success for $user (kind=$PROBE_KIND rc=$PROBE_RC) — control invalid"
}

# Only actual denial counts as protection. success/missing/timeout/unsupported/error ≠ PASS.
expect_rename_blocked(){
  local user="$1" src="$2" dst="$3" label="$4"
  probe_rename "$user" "$src" "$dst" "$label"
  case "$PROBE_KIND" in
    denied)
      log "  BLOCKED_OK $label user=$user kind=denied"
      return 0
      ;;
    success)
      fail "$label: RENAME SUCCEEDED for $user — protection failed"
      ;;
    path_missing)
      fail "$label: path missing — not protection"
      ;;
    timeout)
      fail "$label: timeout — not protection"
      ;;
    unsupported)
      fail "$label: unsupported — not protection"
      ;;
    *)
      fail "$label: probe error kind=$PROBE_KIND rc=$PROBE_RC — not protection"
      ;;
  esac
}

expect_exchange_blocked(){
  local user="$1" src="$2" dst="$3" label="$4"
  probe_exchange "$user" "$src" "$dst" "$label"
  case "$PROBE_KIND" in
    denied)
      log "  BLOCKED_OK $label user=$user kind=denied (renameat2 EXCHANGE)"
      return 0
      ;;
    success)
      fail "$label: RENAME_EXCHANGE SUCCEEDED for $user — protection failed"
      ;;
    path_missing)
      fail "$label: path missing — not protection"
      ;;
    timeout)
      fail "$label: timeout — not protection"
      ;;
    unsupported)
      fail "$label: renameat2 unsupported — not protection PASS"
      ;;
    *)
      fail "$label: probe error kind=$PROBE_KIND rc=$PROBE_RC — not protection"
      ;;
  esac
}

git_as_broker(){
  local repo="$1"; shift
  runuser -u "$BROKER_USER" -- git \
    -c "safe.directory=$repo" \
    -c "core.hooksPath=/dev/null" \
    -c "core.fsmonitor=false" \
    -C "$repo" "$@"
}

# ============================== INNER (mountns) ============================== #
run_inner(){
  [ -n "${ST:-}" ] && [ -n "${OUT:-}" ] || stop inner_env "ST/OUT missing"
  [ -d "$ST" ] || stop inner_st "ST missing: $ST"

  FD_HELPER_PID=""
  MOUNTS=()
  INNER_CLEAN_OK=1

  cleanup_inner(){
    local p i
    if [ -n "${FD_HELPER_PID:-}" ]; then
      if kill -0 "$FD_HELPER_PID" 2>/dev/null; then
        kill "$FD_HELPER_PID" 2>/dev/null || true
      fi
      if ! wait "$FD_HELPER_PID" 2>/dev/null; then
        true
      fi
      FD_HELPER_PID=""
    fi
    # Reverse-order umount of mounts we installed (do not touch foreign mounts).
    if [ "${#MOUNTS[@]}" -gt 0 ]; then
      for ((i=${#MOUNTS[@]}-1; i>=0; i--)); do
        p="${MOUNTS[i]}"
        if findmnt -n -o TARGET --mountpoint "$p" >/dev/null 2>&1; then
          if ! umount "$p"; then
            log "CLEANUP_WARN umount_failed $p"
            INNER_CLEAN_OK=0
          else
            log "  UMOUNT $p"
          fi
        fi
      done
    fi
    MOUNTS=()
  }
  trap cleanup_inner EXIT

  mount --make-rprivate / || fail "mount --make-rprivate / failed"

  # Root-owned container; fake home for zhong; Projects/AppProjects + 3 broker projects.
  HOME_FAKE="$ST/home"
  PROJECTS="$HOME_FAKE/Projects"
  APPPROJECTS="$HOME_FAKE/AppProjects"
  A="$PROJECTS/FakeAEGL"
  B="$PROJECTS/FakeStack"
  C="$APPPROJECTS/FakeKeepLab"
  SIB="$PROJECTS/SiblingOK"

  mkdir -p "$A" "$B" "$C" "$SIB" "$ST/ipc"
  # ST: root-owned, not writable by test UIDs; 0711 = traverse for zhong/ai/broker.
  # (Distinct from root delivery RDIR which stays 0700 outside this script.)
  chown root:root "$ST"
  chmod 0711 "$ST"
  # ipc: root-created, operator-writable (ST itself stays non-writable to tests).
  chown "$OP_USER:$OP_USER" "$ST/ipc"
  chmod 0755 "$ST/ipc"
  chown "$OP_USER:$OP_USER" "$HOME_FAKE" "$PROJECTS" "$APPPROJECTS" "$SIB"
  chmod 0755 "$HOME_FAKE" "$PROJECTS" "$APPPROJECTS" "$SIB"
  chown -R "$BROKER_USER:$HUMAN_GROUP" "$A" "$B" "$C"
  chmod 2750 "$A" "$B" "$C"

  log "== 0. Throwaway git repo (broker) + V1/V2 with explicit V1 restore =="
  git_as_broker "$A" init -q
  runuser -u "$BROKER_USER" -- bash -c "printf 'v1\n' > '$A/body.txt'"
  git_as_broker "$A" -c user.email=t@t -c user.name=t add body.txt
  git_as_broker "$A" -c user.email=t@t -c user.name=t commit -qm v1
  git_as_broker "$A" branch -M main
  V1="$(git_as_broker "$A" rev-parse HEAD)"
  runuser -u "$BROKER_USER" -- bash -c "printf 'v2\n' > '$A/body.txt'"
  git_as_broker "$A" -c user.email=t@t -c user.name=t commit -am v2 -q
  V2="$(git_as_broker "$A" rev-parse HEAD)"
  # Explicit restore to V1: ref + index + body before any mount trial.
  git_as_broker "$A" update-ref refs/heads/main "$V1"
  git_as_broker "$A" restore --source="$V1" --staged --worktree -- .
  chown -R "$BROKER_USER:$HUMAN_GROUP" "$A"
  chmod 2750 "$A"
  ref_now="$(git_as_broker "$A" rev-parse refs/heads/main)"
  [ "$ref_now" = "$V1" ] || fail "ref not V1 after restore (got $ref_now)"
  idx_blob="$(git_as_broker "$A" rev-parse :body.txt)"
  v1_blob="$(git_as_broker "$A" rev-parse "$V1:body.txt")"
  [ "$idx_blob" = "$v1_blob" ] || fail "index body blob != V1:body.txt"
  body_txt="$(runuser -u "$BROKER_USER" -- cat "$A/body.txt")"
  [ "$body_txt" = "v1" ] || fail "worktree body not v1 after restore"
  body_blob="$(runuser -u "$BROKER_USER" -- git hash-object -t blob -- "$A/body.txt")"
  [ "$body_blob" = "$v1_blob" ] || fail "worktree body hash != V1 blob"
  log "  V1_RESTORE_OK ref=$V1 index=$idx_blob body=v1"

  log "== 1. PRE-MOUNT CONTROL (must succeed) =="
  expect_rename_ok "$OP_USER" "$A" "$PROJECTS/FakeAEGL.control-moved" "control_op_rename_project"
  expect_rename_ok "$OP_USER" "$PROJECTS/FakeAEGL.control-moved" "$A" "control_op_rename_project_back"
  expect_exchange_ok "$OP_USER" "$A" "$B" "control_op_exchange_AEGL_Stack"
  # exchange swapped names — swap back
  expect_exchange_ok "$OP_USER" "$A" "$B" "control_op_exchange_AEGL_Stack_back"
  expect_rename_ok "$OP_USER" "$SIB" "$PROJECTS/SiblingOK.moved" "control_op_rename_sibling"
  expect_rename_ok "$OP_USER" "$PROJECTS/SiblingOK.moved" "$SIB" "control_op_rename_sibling_back"
  probe_rename "$AI_USER" "$A" "$PROJECTS/FakeAEGL.ai-pre" "control_ai_rename_project"
  if [ "$PROBE_KIND" = success ]; then
    expect_rename_ok "$AI_USER" "$PROJECTS/FakeAEGL.ai-pre" "$A" "control_ai_rename_project_back"
    log "  AI_PRE_MOUNT_RENAME=possible"
  else
    log "  AI_PRE_MOUNT_RENAME=kind=$PROBE_KIND (not counted as bind-mount proof)"
  fi

  log "== 1b. Helper holding Projects dir fd (before mounts) =="
  FD_PATH="$ST/ipc/held.fd"
  rm -f "$FD_PATH" "$FD_PATH.go" "$ST/ipc/fd-rename.out"
  runuser -u "$OP_USER" -- env FD_PATH="$FD_PATH" PARENT="$PROJECTS" OUT_FD="$ST/ipc/fd-rename.out" \
    python3 - <<'PY' &
import errno, os, time
fd_path = os.environ["FD_PATH"]
parent = os.environ["PARENT"]
out_path = os.environ["OUT_FD"]
DENIED_ERRNOS = {errno.EBUSY, errno.EACCES, errno.EPERM}
UNSUPPORTED_ERRNOS = {errno.ENOSYS}
if hasattr(errno, "EOPNOTSUPP"):
    UNSUPPORTED_ERRNOS.add(errno.EOPNOTSUPP)

def classify_errno(e):
    if e == errno.ENOENT:
        return "path_missing", 11
    if e in UNSUPPORTED_ERRNOS:
        return "unsupported", 13
    if e in DENIED_ERRNOS:
        return "denied", 1
    return "error", 99

def emit(kind, rc, errno_v, msg=""):
    ename = errno.errorcode.get(errno_v, "?") if errno_v else "0"
    open(out_path, "w", encoding="utf-8").write(
        f"PROBE fd_rename user=zhong op=rename kind={kind} rc={rc} "
        f"errno={errno_v}({ename}) via_held_parent_fd{msg}\n")

fd = os.open(parent, os.O_RDONLY)
open(fd_path, "w", encoding="utf-8").write(str(fd))
go = fd_path + ".go"
for _ in range(400):
    if os.path.exists(go):
        break
    time.sleep(0.05)
else:
    emit("timeout", -1, 0)
    os._exit(12)
src = f"/proc/self/fd/{fd}/FakeAEGL"
dst = f"/proc/self/fd/{fd}/FakeAEGL.fd-hijack"
try:
    os.rename(src, dst)
    emit("success", 0, 0)
    os._exit(0)
except OSError as e:
    kind, code = classify_errno(e.errno)
    emit(kind, -1, e.errno)
    os._exit(code)
except Exception as e:
    emit("error", -1, 0, f" detail={e!r}")
    os._exit(99)
PY
  FD_HELPER_PID=$!
  waited=0
  while [ "$waited" -lt 100 ]; do
    if [ -f "$FD_PATH" ]; then
      break
    fi
    sleep 0.05
    waited=$((waited + 1))
  done
  [ -f "$FD_PATH" ] || fail "fd helper did not publish held fd (timeout)"
  log "  FD_HELPER_PID=$FD_HELPER_PID"

  log "== 2. RW bind mounts: parents first, then projects =="
  bind_one(){
    local p="$1"
    mount --bind "$p" "$p" || fail "mount --bind failed: $p"
    MOUNTS+=("$p")
    assert_exact_mountpoint "$p"
    log "  BIND_RW $p"
  }
  bind_one "$PROJECTS"
  bind_one "$APPPROJECTS"
  bind_one "$A"
  bind_one "$B"
  bind_one "$C"
  # All five exact mountpoints
  assert_exact_mountpoint "$PROJECTS"
  assert_exact_mountpoint "$APPPROJECTS"
  assert_exact_mountpoint "$A"
  assert_exact_mountpoint "$B"
  assert_exact_mountpoint "$C"
  log "  FIVE_MOUNTPOINTS_OK"

  log "== 3. POST-MOUNT: project rename / exchange must be denied =="
  expect_rename_blocked "$OP_USER" "$A" "$PROJECTS/FakeAEGL.op-moved" "post_op_rename_FakeAEGL"
  expect_rename_blocked "$OP_USER" "$B" "$PROJECTS/FakeStack.op-moved" "post_op_rename_FakeStack"
  expect_rename_blocked "$OP_USER" "$C" "$APPPROJECTS/FakeKeepLab.op-moved" "post_op_rename_FakeKeepLab"
  expect_exchange_blocked "$OP_USER" "$A" "$B" "post_op_exchange_AEGL_Stack"
  expect_rename_blocked "$AI_USER" "$A" "$PROJECTS/FakeAEGL.ai-moved" "post_ai_rename_FakeAEGL"
  expect_exchange_blocked "$AI_USER" "$A" "$B" "post_ai_exchange_AEGL_Stack"

  log "== 4. POST-MOUNT: both parent entries must be denied =="
  expect_rename_blocked "$OP_USER" "$PROJECTS" "$HOME_FAKE/Projects.moved" "post_op_rename_Projects"
  expect_rename_blocked "$OP_USER" "$APPPROJECTS" "$HOME_FAKE/AppProjects.moved" "post_op_rename_AppProjects"
  expect_rename_blocked "$AI_USER" "$PROJECTS" "$HOME_FAKE/Projects.ai-moved" "post_ai_rename_Projects"
  expect_exchange_blocked "$OP_USER" "$PROJECTS" "$APPPROJECTS" "post_op_exchange_parents"

  log "== 5. Unprotected sibling still usable =="
  expect_rename_ok "$OP_USER" "$SIB" "$PROJECTS/SiblingOK.moved" "post_op_sibling_rename"
  expect_rename_ok "$OP_USER" "$PROJECTS/SiblingOK.moved" "$SIB" "post_op_sibling_rename_back"

  log "== 6. Held parent-fd rename (started before mounts) =="
  touch "$FD_PATH.go"
  fd_rc=0
  if wait "$FD_HELPER_PID"; then
    fd_rc=0
  else
    fd_rc=$?
  fi
  FD_HELPER_PID=""
  [ -f "$ST/ipc/fd-rename.out" ] || fail "fd helper produced no output"
  log "$(cat "$ST/ipc/fd-rename.out")"
  case "$fd_rc" in
    1)
      # exit 1 only emitted for EBUSY/EACCES/EPERM by classify_errno
      if grep -q 'kind=denied' "$ST/ipc/fd-rename.out" \
         && grep -qE 'errno=[0-9]+\((EBUSY|EACCES|EPERM)\)' "$ST/ipc/fd-rename.out"; then
        log "  BLOCKED_OK fd_rename via_held_parent_fd"
      else
        fail "fd_rename exit 1 without strict denied errno: $(cat "$ST/ipc/fd-rename.out")"
      fi
      ;;
    0)
      fail "fd_rename SUCCEEDED via held parent fd — protection failed"
      ;;
    11)
      fail "fd_rename path_missing — not protection"
      ;;
    12)
      fail "fd_rename timeout — not protection"
      ;;
    13)
      fail "fd_rename unsupported — not protection"
      ;;
    99)
      fail "fd_rename unexpected errno/error — not protection ($(cat "$ST/ipc/fd-rename.out"))"
      ;;
    *)
      fail "fd_rename abnormal exit=$fd_rc — not protection ($(cat "$ST/ipc/fd-rename.out"))"
      ;;
  esac

  log "== 7. Broker CAS + body sync under RW binds =="
  [ "$(runuser -u "$BROKER_USER" -- cat "$A/body.txt")" = "v1" ] || fail "body not v1 before CAS"
  git_as_broker "$A" update-ref refs/heads/main "$V2" "$V1" \
    || fail "broker update-ref CAS failed under bind mounts"
  [ "$(git_as_broker "$A" rev-parse refs/heads/main)" = "$V2" ] || fail "ref not V2 after CAS"
  [ "$(runuser -u "$BROKER_USER" -- cat "$A/body.txt")" = "v1" ] \
    || fail "CAS unexpectedly changed worktree body"
  git_as_broker "$A" restore --source=HEAD --staged --worktree -- . \
    || fail "broker restore/sync failed under bind mounts"
  [ "$(runuser -u "$BROKER_USER" -- cat "$A/body.txt")" = "v2" ] \
    || fail "broker sync did not land tip body"
  log "  BROKER_CAS_SYNC=OK"

  log "== 8. Operator cannot write project body =="
  if runuser -u "$OP_USER" -- bash --noprofile --norc -c 'builtin test -w "$1"' _ "$A/body.txt" 2>/dev/null; then
    fail "operator can write FakeAEGL body"
  fi
  log "  OPERATOR_BODY_WRITE=denied"

  # Inner cleanup (umount + helper) before declaring OK.
  cleanup_inner
  trap - EXIT
  if [ "$INNER_CLEAN_OK" != 1 ]; then
    fail "inner cleanup failed (umount) — not reporting full success"
  fi
  log "PARENT_RENAME_BIND_TRIAL_INNER=OK"
  say "PARENT_RENAME_BIND_TRIAL_INNER=OK"
  # Outer deletes ST; do not rm -rf ST here.
  exit 0
}

# ============================== OUTER ============================== #
if [ "$MODE" = inner ]; then
  # Env inherited from outer unshare child.
  run_inner
  exit $?
fi

[ "$(id -u)" = 0 ] || stop need_root "trial requires root"
[ -n "$TIP_EXPECT" ] || stop need_commit "--commit <40-hex formal baseline> required"
[ "${#TIP_EXPECT}" -eq 40 ] || stop bad_sha "--commit must be 40-hex"
case "$TIP_EXPECT" in [0-9a-f]*) ;; *) stop bad_sha "--commit must be 40-hex" ;; esac
for u in "$OP_USER" "$AI_USER" "$BROKER_USER"; do
  id "$u" >/dev/null 2>&1 || stop missing_user "$u"
done
getent group "$HUMAN_GROUP" >/dev/null || stop missing_group "$HUMAN_GROUP"
command -v unshare >/dev/null || stop missing_unshare
command -v mount >/dev/null || stop missing_mount
command -v findmnt >/dev/null || stop missing_findmnt
command -v python3 >/dev/null || stop missing_python

[ -d "$FORMAL_AEGL/.git" ] || stop formal_missing "$FORMAL_AEGL"
# Formal baseline via broker UID + command-level exact safe.directory (not user script claim).
main_now="$(runuser -u "$BROKER_USER" -- git \
  -c "safe.directory=$FORMAL_AEGL" \
  -C "$FORMAL_AEGL" rev-parse refs/heads/main)"
[ "$main_now" = "$TIP_EXPECT" ] \
  || stop tip_mismatch "formal main=$main_now want=$TIP_EXPECT (baseline pin only; script not claimed in that commit)"

say "PARENT_RENAME_BIND_TRIAL begin formal_baseline=$TIP_EXPECT"
say "SCRIPT_IN_COMMIT=not_claimed"
say "AI_BOUNDARY=BLOCKED"
say "DEPLOY_FORMAL=no"

ST="$(mktemp -d /var/tmp/aegl-parent-rename-trial-XXXXXX)" || stop mktemp_failed
# Trial container: root-owned + 0711 traverse (not RDIR 0700 delivery dir).
chown root:root "$ST"
chmod 0711 "$ST"
OUT="$ST/results.txt"
: > "$OUT"
SELF="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || printf '%s\n' "$0")"
NS_PID=""
OUTER_CLEAN_OK=1
NS_RC=0

cleanup_outer(){
  if [ -n "${NS_PID:-}" ] && kill -0 "$NS_PID" 2>/dev/null; then
    kill "$NS_PID" 2>/dev/null || true
    if ! wait "$NS_PID" 2>/dev/null; then
      true
    fi
    NS_PID=""
  fi
  if [ -n "${ST:-}" ] && [ -d "$ST" ]; then
    if ! rm -rf "$ST"; then
      OUTER_CLEAN_OK=0
      printf 'CLEANUP_FAIL: could not remove %s\n' "$ST" >&2
    fi
  fi
}
trap cleanup_outer EXIT

# Keep outer control: unshare as child (no exec). if/else preserves errexit.
unshare -m env \
  ST="$ST" \
  OUT="$OUT" \
  TIP_EXPECT="$TIP_EXPECT" \
  FORMAL_AEGL="$FORMAL_AEGL" \
  OP_USER="$OP_USER" \
  AI_USER="$AI_USER" \
  BROKER_USER="$BROKER_USER" \
  HUMAN_GROUP="$HUMAN_GROUP" \
  bash "$SELF" --inner --commit "$TIP_EXPECT" --aegl "$FORMAL_AEGL" &
NS_PID=$!
NS_RC=0
if wait "$NS_PID"; then
  NS_RC=0
else
  NS_RC=$?
fi
NS_PID=""

if [ -f "$OUT" ]; then
  say "---- trial log (tail) ----"
  tail -n 60 "$OUT" || true
fi

if [ "$NS_RC" != 0 ]; then
  stop trial_failed "mountns child exit=$NS_RC"
fi

# Outer deletes ST after child exit; cleanup failure ⇒ not full success.
cleanup_outer
trap - EXIT
if [ "$OUTER_CLEAN_OK" != 1 ]; then
  stop cleanup_failed "temp dir removal failed — not reporting full success"
fi

say "PARENT_RENAME_BIND_TRIAL_RESULT=OK formal_baseline=$TIP_EXPECT"
say "SCRIPT_IN_COMMIT=not_claimed"
say "AI_BOUNDARY=BLOCKED"
say "FORMAL_DEPLOY=not_done"
say "STOP_AT=complete"
exit 0
