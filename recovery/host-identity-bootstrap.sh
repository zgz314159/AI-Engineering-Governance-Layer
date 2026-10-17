#!/usr/bin/env bash
# host-identity-bootstrap.sh — AEGL host identity prepare / switch / verify.
#
# Trusted delivery (fixed full SHA; works when piped — never requires BASH_SOURCE):
#   git -C "$AEGL" show "$TIP:recovery/host-identity-bootstrap.sh" \
#     | sudo bash -s -- --commit "$TIP" --aegl "$AEGL" <plan|prepare|switch|verify|...>
#
# Modes:
#   plan              print everything; change nothing
#   prepare           idempotent accounts/groups/state-root (no project permission change)
#   deps-plan         freeze the two node_modules paths + external rebuild wiring (no delete)
#   broker-bind       verify installed broker matches --commit; write broker-verified only then
#   switch-preflight  throwaway: writable → switch-like perms → non-priv denied; broker CAS
#   switch            final permission change on the THREE formal trees only (gated)
#   verify            non-mutating acceptance (builtin test -w as target identities)
#   selftest          destructive probes only in /var/tmp throwaway
#   broker-plan       print install-broker handoff (does NOT install or write marker)
#
# Failures stop immediately with STOP_AT=<phase>. No fake success after a failed step.
# No recursive symlink follow (-P). No chattr on whole Projects/AppProjects this round.
# No backups/archives. No sudo elevation from inside this script.
set -euo pipefail

COMMIT=""
AEGL_ARG=""
MODE=""
WRITE_MARKER=0

while [ $# -gt 0 ]; do
  case "$1" in
    --commit) COMMIT="${2:-}"; shift 2 ;;
    --aegl) AEGL_ARG="${2:-}"; shift 2 ;;
    --write-marker) WRITE_MARKER=1; shift ;;
    plan|prepare|switch|verify|selftest|broker-plan|broker-bind|deps-plan|switch-preflight)
      MODE="$1"; shift ;;
    --plan) MODE=plan; shift ;;
    *) printf 'STOP_AT=bad_option\nHOST_ERROR: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -n "$MODE" ] || MODE=plan

AI_USER="aegl-ai";          AI_GROUP="aegl-ai"
BROKER_USER="aegl-promote"; BROKER_GROUP="aegl-broker"
HUMAN_GROUP="aegl-ro"
OPERATOR_USER="${SUDO_USER:-zhong}"
[ "$OPERATOR_USER" = root ] && OPERATOR_USER=zhong
AI_STATE_ROOT="/var/lib/aegl-ai"
BROKER_MARKER="/etc/aegl/broker-verified"
BROKER_LIBDIR="/usr/local/lib/aegl-promote"
BROKER_UNIT="/etc/systemd/system/aegl-promote-broker.service"

HOME_DIR="/home/zhong"
PROJECTS_PARENT="/home/zhong/Projects"
BUSINESS_PARENT="/home/zhong/AppProjects"
AEGL_DEFAULT="$PROJECTS_PARENT/AI-Engineering-Governance-Layer"
STACK_DEFAULT="$PROJECTS_PARENT/Google-Android-Agent-Development-Stack"
KEEPLAB_DEFAULT="$BUSINESS_PARENT/KeepLab-Relay"

# Resolve AEGL path without relying on BASH_SOURCE when piped.
if [ -n "$AEGL_ARG" ]; then
  AEGL_ROOT="$(cd "$AEGL_ARG" && pwd)"
elif [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  AEGL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
else
  AEGL_ROOT="$AEGL_DEFAULT"
fi

PROJECTS=(
  "$AEGL_DEFAULT"
  "$STACK_DEFAULT"
)
BUSINESS_PROJECTS=(
  "$KEEPLAB_DEFAULT"
)

# Exact generated trees from the existing review list (never auto-deleted here).
GENERATED_DEPS=(
  "$AEGL_DEFAULT/fixture/.specify/extensions/architecture-guard/node_modules"
  "$AEGL_DEFAULT/upstream/rulesync/node_modules"
)
# Declared rebuildable locations outside formal trees (wiring only this round).
EXTERNAL_DEP_ROOT="/var/lib/aegl/rebuildable-deps"
EXTERNAL_DEP_RULESYNC="$EXTERNAL_DEP_ROOT/rulesync/node_modules"
EXTERNAL_DEP_ARCHGUARD="$EXTERNAL_DEP_ROOT/architecture-guard/node_modules"

PHASE="init"
say(){ printf '%s\n' "$*"; }
phase(){ PHASE="$1"; printf '\n== %s ==\n' "$1"; }
stop(){ printf 'STOP_AT=%s\n' "$1" >&2; shift; printf 'HOST_ERROR: %s\n' "$*" >&2; exit 1; }

require_commit(){
  [ -n "$COMMIT" ] || stop need_commit "--commit <full 40-hex> required for trusted delivery"
  case "$COMMIT" in [0-9a-f]*) ;; *) stop bad_sha "--commit must be 40-hex" ;; esac
  [ "${#COMMIT}" -eq 40 ] || stop bad_sha "--commit must be 40-hex (got ${#COMMIT})"
  git -C "$AEGL_ROOT" cat-file -e "$COMMIT^{commit}" 2>/dev/null \
    || stop commit_missing "$COMMIT not in $AEGL_ROOT"
  git -C "$AEGL_ROOT" cat-file -e "$COMMIT:recovery/host-identity-bootstrap.sh" 2>/dev/null \
    || stop tip_missing_script "host-identity-bootstrap.sh missing in $COMMIT"
}

# execute only in prepare/switch; always fail-stop
run(){
  printf '  $ %s\n' "$*"
  if [ "$MODE" = prepare ] || [ "$MODE" = switch ]; then
    "$@" || stop "run_failed_$PHASE" "command failed: $*"
  fi
}

# Target-identity write check via Bash builtin (never /usr/bin/test).
as_user_test_w(){
  local user="$1" path="$2"
  if [ "$(id -u)" = 0 ]; then
    runuser -u "$user" -- bash --noprofile --norc -c 'builtin test -w "$1"' _ "$path"
  else
    bash --noprofile --norc -c 'builtin test -w "$1"' _ "$path"
  fi
}

# --------------------------------------------------------------------------- #
# deps-plan — freeze two node_modules; wire external rebuild roots (no delete)
# --------------------------------------------------------------------------- #
list_generated_deps(){
  phase "deps-plan (review freeze; nothing deleted)"
  local d
  for d in "${GENERATED_DEPS[@]}"; do
    if [ ! -e "$d" ]; then say "  (absent) $d"; continue; fi
    local dev rdev sz nf tracked nlink_gt1
    dev="$(stat -c '%d' "$d")"; rdev="$(stat -c '%d' "$AEGL_DEFAULT")"
    sz="$(du -sh "$d" 2>/dev/null | cut -f1)"
    nf="$(find -P "$d" -type f 2>/dev/null | wc -l)"
    tracked="$(git -C "$AEGL_DEFAULT" ls-files -- "${d#"$AEGL_DEFAULT/"}" 2>/dev/null | wc -l)"
    nlink_gt1="$(find -P "$d" -type f -links +1 2>/dev/null | wc -l)"
    say "  FREEZE_PATH=$d"
    say "    size=$sz files=$nf tracked=$tracked hardlinks_gt1=$nlink_gt1"
    say "    symlink=$([ -L "$d" ] && echo yes || echo no) samedev=$([ "$dev" = "$rdev" ] && echo yes || echo NO)"
    say "    unique_source=no (gitignored regenerable from package.json / lockfile)"
  done
  say "  EXTERNAL_DEP_ROOT=$EXTERNAL_DEP_ROOT"
  say "  EXTERNAL_RULESYNC=$EXTERNAL_DEP_RULESYNC"
  say "  EXTERNAL_ARCHGUARD=$EXTERNAL_DEP_ARCHGUARD"
  say "  ENV_FILE_DECLARED=/etc/aegl/rebuildable-deps.env  (print-only this round; not written)"
  say "  REBUILD_HINT_RULESYNC=mkdir -p $EXTERNAL_DEP_ROOT/rulesync && cd $AEGL_DEFAULT/upstream/rulesync && pnpm install --frozen-lockfile --dir $EXTERNAL_DEP_ROOT/rulesync"
  say "  REBUILD_HINT_ARCHGUARD=mkdir -p $EXTERNAL_DEP_ROOT/architecture-guard && cd $AEGL_DEFAULT/fixture/.specify/extensions/architecture-guard && pnpm install --frozen-lockfile --dir $EXTERNAL_DEP_ROOT/architecture-guard"
  say "  ENV_HINT_CONTENT=NODE_PATH=$EXTERNAL_DEP_RULESYNC:$EXTERNAL_DEP_ARCHGUARD"
  say "  ENTRY_RULESYNC=bin/aegl-recovery doctor uses upstream/rulesync/dist/cli (prebuilt; --help OK without in-tree node_modules)"
  say "  ENTRY_ARCHGUARD=fixture tests/dev import packages from in-tree node_modules — rebuild to EXTERNAL_ARCHGUARD before delete"
  say "  BEFORE_DELETE=populate EXTERNAL_* + export NODE_PATH (or mise env) so RuleSync/doctor/tests stay runnable"
  say "  THIS_ROUND=prepare_wiring_only; formal delete NOT executed"
  say "  DEPS_PLAN_OK=1"
}

# --------------------------------------------------------------------------- #
# verify (non-mutating)
# --------------------------------------------------------------------------- #
VFAIL=0
check(){
  local label="$1" want="$2" user="$3" path="$4"
  printf '  %-46s ' "$label"
  local got=no
  if as_user_test_w "$user" "$path"; then got=ok; else got=no; fi
  if [ "$got" = "$want" ]; then echo "$got (expected $want)"
  else echo "$got (EXPECTED $want)"; VFAIL=$((VFAIL+1)); fi
}
verify_target(){
  local p="$1"
  say "  --- $p"
  local nested=""
  nested="$(find -P "$p" -path "$p/.git" -prune -o -type f -print -quit 2>/dev/null || true)"
  check "operator cannot write project root"   no  "$OPERATOR_USER" "$p"
  if [ -n "$nested" ]; then check "operator cannot write a nested file" no "$OPERATOR_USER" "$nested"; fi
  if [ -e "$p/.git/config" ]; then check "operator cannot write .git config" no "$OPERATOR_USER" "$p/.git/config"; fi
  check "broker can write the project root"    ok  "$BROKER_USER"   "$p"
  # Operator must still be able to read (HUMAN_GROUP / world-read as designed).
  if [ "$(id -u)" = 0 ]; then
    if runuser -u "$OPERATOR_USER" -- bash --noprofile --norc -c 'builtin test -r "$1"' _ "$p"; then
      say "  operator can read project root: ok"
    else
      say "  operator can read project root: FAIL"; VFAIL=$((VFAIL+1))
    fi
  fi
  say "    PARENT_RENAME_PROTECTION=UNRESOLVED (no chattr on $PROJECTS_PARENT / $BUSINESS_PARENT this round)"
  say "    (file/dir non-write ≠ complete isolation against parent rename/replace)"
}
do_verify(){
  phase "verify"
  local p
  for p in "${PROJECTS[@]}" "${BUSINESS_PROJECTS[@]}"; do
    [ -e "$p" ] || stop verify_missing "manifest path missing: $p"
    verify_target "$p"
  done
  say "  VERIFY_VIOLATIONS=$VFAIL"
  [ "$VFAIL" -eq 0 ] || stop verify_failed "VERIFY_VIOLATIONS=$VFAIL"
  say "VERIFY_RESULT=OK"
}

# --------------------------------------------------------------------------- #
# prepare
# --------------------------------------------------------------------------- #
preflight_paths(){
  local p
  for p in "${PROJECTS[@]}" "${BUSINESS_PROJECTS[@]}" "$PROJECTS_PARENT" "$BUSINESS_PARENT" "$HOME_DIR"; do
    if [ ! -e "$p" ]; then stop path_missing "manifest path missing: $p"; fi
    if [ -L "$p" ]; then stop path_symlink "manifest path is a symlink: $p"; fi
  done
  return 0
}
prepare(){
  phase "prepare"
  preflight_paths
  getent group "$AI_GROUP"     >/dev/null || run groupadd --system "$AI_GROUP"
  getent group "$BROKER_GROUP" >/dev/null || run groupadd --system "$BROKER_GROUP"
  getent group "$HUMAN_GROUP"  >/dev/null || run groupadd --system "$HUMAN_GROUP"
  id "$AI_USER"     >/dev/null 2>&1 || run useradd --system --no-create-home --shell /usr/sbin/nologin --gid "$AI_GROUP" "$AI_USER"
  id "$BROKER_USER" >/dev/null 2>&1 || run useradd --system --no-create-home --shell /usr/sbin/nologin --gid "$BROKER_GROUP" "$BROKER_USER"
  run usermod -aG "$HUMAN_GROUP" "$OPERATOR_USER"
  run install -d -o "$AI_USER" -g "$BROKER_GROUP" -m 2770 "$AI_STATE_ROOT"
  say "  LOGIN_GROUP_NOTE: if zhong was just added to $HUMAN_GROUP, refresh the login session"
  say "    (newgrp $HUMAN_GROUP, or log out/in) before relying on group read bits."
  say "PREPARE_RESULT=OK"
}

# --------------------------------------------------------------------------- #
# broker-bind — reuse installed broker; never reinstall; marker only with evidence
# --------------------------------------------------------------------------- #
broker_bind(){
  phase "broker-bind"
  require_commit
  [ -x "$BROKER_LIBDIR/aegl-promote-broker" ] || stop broker_missing "installed broker missing: $BROKER_LIBDIR"
  systemctl is-active --quiet aegl-promote-broker \
    || stop broker_inactive "aegl-promote-broker not active"
  local f base tip_hash inst_hash
  for f in bin/aegl-promote-broker recovery/promotion_broker.py recovery/promotion_core.py; do
    base="$(basename "$f")"
    tip_hash="$(git -C "$AEGL_ROOT" show "$COMMIT:$f" | sha256sum | awk '{print $1}')"
    inst_hash="$(sha256sum "$BROKER_LIBDIR/$base" | awk '{print $1}')"
    [ "$tip_hash" = "$inst_hash" ] \
      || stop broker_drift "$base tip=$tip_hash installed=$inst_hash (refusing marker; do not reinstall here)"
    say "  BROKER_MATCH $base"
  done
  # Evidence: tip file match + active unit + unit business-root + optional registry.
  # Never touch-only a marker without the hash match above.
  local reg="/var/lib/aegl-promote" reg_entries=0
  if [ -d "$reg" ] && [ -r "$reg" ]; then
    reg_entries="$(find -P "$reg" -mindepth 1 -maxdepth 2 2>/dev/null | wc -l)"
    say "  REGISTRY_READABLE=yes dir=$reg entries=$reg_entries"
  else
    say "  REGISTRY_READABLE=no (root-only or absent) — marker still requires tip/file match + active unit"
  fi
  local biz
  biz="$(grep -E '^Environment=AEGL_BUSINESS_ROOT=' "$BROKER_UNIT" 2>/dev/null || true)"
  [ -n "$biz" ] || stop broker_unit "AEGL_BUSINESS_ROOT missing from $BROKER_UNIT"
  say "  UNIT_BUSINESS_ROOT=$biz"
  say "  FORMAL_TIPS aegl_main=$(git -C "$AEGL_DEFAULT" rev-parse refs/heads/main) stack_master=$(git -C "$STACK_DEFAULT" rev-parse refs/heads/master) keeplab_master=$(git -C "$KEEPLAB_DEFAULT" rev-parse refs/heads/master)"
  if [ "$WRITE_MARKER" = 1 ]; then
    [ "$(id -u)" = 0 ] || stop need_root "broker-bind --write-marker requires root"
    umask 022
    printf 'broker_verified commit=%s tip_match=sha256_of_installed_broker_files aegl_main=%s stack_master=%s keeplab_master=%s unit_active=1 ts=%s\n' \
      "$COMMIT" \
      "$(git -C "$AEGL_DEFAULT" rev-parse refs/heads/main)" \
      "$(git -C "$STACK_DEFAULT" rev-parse refs/heads/master)" \
      "$(git -C "$KEEPLAB_DEFAULT" rev-parse refs/heads/master)" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      > "$BROKER_MARKER"
    chown root:root "$BROKER_MARKER"
    chmod 0644 "$BROKER_MARKER"
    say "  WROTE $BROKER_MARKER (evidence=tip_sha256_match+unit_active+formal_tips; not a bare touch)"
  else
    say "  MARKER_WRITE=skipped (pass --write-marker as root after review)"
    if [ -f "$BROKER_MARKER" ]; then say "  MARKER_PRESENT=$(cat "$BROKER_MARKER")"; else say "  MARKER_PRESENT=absent"; fi
  fi
  say "BROKER_BIND_RESULT=OK"
}

# --------------------------------------------------------------------------- #
# switch-preflight — throwaway identity/CAS check before formal switch
# --------------------------------------------------------------------------- #
switch_preflight(){
  phase "switch-preflight"
  if [ "$(id -u)" != 0 ]; then
    say "SWITCH_PREFLIGHT=NOT_RUN need_root (not faking cross-UID PASS)"
    return 0
  fi
  id "$BROKER_USER" >/dev/null 2>&1 || stop missing_broker_user "$BROKER_USER"
  id "$OPERATOR_USER" >/dev/null 2>&1 || stop missing_op "$OPERATOR_USER"
  id "$AI_USER" >/dev/null 2>&1 || stop missing_ai "$AI_USER"
  command -v setfacl >/dev/null 2>&1 || stop missing_setfacl "setfacl required"

  local ST PROJ V1 V2
  ST="$(mktemp -d /var/tmp/aegl-host-switch-pf-XXXXXX)" || stop mktemp_failed "mktemp"
  cleanup_pf(){ chmod -R u+w "$ST" 2>/dev/null || true; rm -rf "$ST"; }
  trap cleanup_pf EXIT

  PROJ="$ST/Demo"
  runuser -u "$OPERATOR_USER" -- mkdir -p "$PROJ/sub" "$PROJ/.git"
  runuser -u "$OPERATOR_USER" -- bash -c "printf 'v1\n' > '$PROJ/sub/f.txt'; printf 'c\n' > '$PROJ/.git/config'"
  # Before: operator can write
  as_user_test_w "$OPERATOR_USER" "$PROJ/sub/f.txt" \
    || stop preflight_before "operator should write before switch-like perms"
  say "  BEFORE_WRITE=ok"

  # Apply switch-like ownership/modes on throwaway only (not formal trees).
  find -P "$PROJ" -path "$PROJ/.git" -prune -o -type d -exec chown "$BROKER_USER:$HUMAN_GROUP" {} + -exec chmod 2750 {} +
  find -P "$PROJ" -path "$PROJ/.git" -prune -o -type f -exec chown "$BROKER_USER:$HUMAN_GROUP" {} + -exec chmod 0640 {} +
  find -P "$PROJ/.git" -type d -exec chown "$BROKER_USER:$BROKER_GROUP" {} + -exec chmod 2700 {} +
  find -P "$PROJ/.git" -type f -exec chown "$BROKER_USER:$BROKER_GROUP" {} + -exec chmod 0600 {} +

  if as_user_test_w "$OPERATOR_USER" "$PROJ/sub/f.txt"; then
    stop preflight_after "operator still can write after switch-like perms"
  fi
  say "  AFTER_OPERATOR_WRITE=denied"
  if as_user_test_w "$AI_USER" "$PROJ/sub/f.txt"; then
    stop preflight_ai "aegl-ai can write after switch-like perms"
  fi
  say "  AFTER_AI_WRITE=denied"
  as_user_test_w "$BROKER_USER" "$PROJ" \
    || stop preflight_broker "broker cannot write project root after switch-like perms"
  say "  AFTER_BROKER_WRITE=ok"

  # Minimal git CAS as broker on a separate throwaway repo (checked-out branch).
  # Basename must match ACL allowlist.
  local GREPO="$ST/AI-Engineering-Governance-Layer"
  runuser -u "$OPERATOR_USER" -- git init -q "$GREPO"
  runuser -u "$OPERATOR_USER" -- bash -c "printf 'a\n' > '$GREPO/body.txt'"
  runuser -u "$OPERATOR_USER" -- git -C "$GREPO" add -A
  runuser -u "$OPERATOR_USER" -- git -C "$GREPO" -c user.email=t@t -c user.name=t commit -qm a
  runuser -u "$OPERATOR_USER" -- git -C "$GREPO" branch -M main
  V1="$(runuser -u "$OPERATOR_USER" -- git -C "$GREPO" rev-parse HEAD)"
  runuser -u "$OPERATOR_USER" -- git -C "$GREPO" checkout -q -b cand
  runuser -u "$OPERATOR_USER" -- bash -c "printf 'b\n' > '$GREPO/body.txt'"
  runuser -u "$OPERATOR_USER" -- git -C "$GREPO" add -A
  runuser -u "$OPERATOR_USER" -- git -C "$GREPO" -c user.email=t@t -c user.name=t commit -qm b
  V2="$(runuser -u "$OPERATOR_USER" -- git -C "$GREPO" rev-parse HEAD)"
  runuser -u "$OPERATOR_USER" -- git -C "$GREPO" checkout -q main
  # ACL for broker CAS (production installer from tip if COMMIT set; else minimal)
  if [ -n "$COMMIT" ]; then
    git -C "$AEGL_ROOT" show "$COMMIT:recovery/install-promote-target-acl.sh" \
      | bash -s -- --repo "$AEGL_ROOT" --project "$GREPO" --commit "$COMMIT" \
           --target-ref refs/heads/main \
      || stop preflight_acl "ACL install on throwaway gitrepo failed"
  else
    stop need_commit "switch-preflight with broker CAS requires --commit"
  fi
  local body_before body_after
  body_before="$(runuser -u "$OPERATOR_USER" -- cat "$GREPO/body.txt")"
  [ "$body_before" = "a" ] || stop preflight_body "expected body a before CAS"
  runuser -u "$BROKER_USER" -- git \
    -c "safe.directory=$GREPO" -c "core.hooksPath=/dev/null" \
    -c "core.fsmonitor=false" -c "core.attributesFile=/dev/null" \
    -C "$GREPO" update-ref refs/heads/main "$V2" "$V1" \
    || stop preflight_cas "broker update-ref CAS failed"
  [ "$(runuser -u "$OPERATOR_USER" -- git -C "$GREPO" rev-parse refs/heads/main)" = "$V2" ] \
    || stop preflight_ref "ref not at V2"
  body_after="$(runuser -u "$OPERATOR_USER" -- cat "$GREPO/body.txt")"
  [ "$body_after" = "a" ] || stop preflight_sync "CAS changed worktree before sync"
  # Necessary sync as operator restore
  runuser -u "$OPERATOR_USER" -- git -C "$GREPO" restore --source=HEAD --staged --worktree -- .
  [ "$(runuser -u "$OPERATOR_USER" -- cat "$GREPO/body.txt")" = "b" ] \
    || stop preflight_restore "restore did not land tip content"

  cleanup_pf
  trap - EXIT
  say "SWITCH_PREFLIGHT_RESULT=OK"
}

# --------------------------------------------------------------------------- #
# switch — three formal trees only
# --------------------------------------------------------------------------- #
switch_preconditions(){
  [ -f "$BROKER_MARKER" ] || {
    say "  REFUSE: broker not verified ($BROKER_MARKER absent) — run broker-bind --write-marker after match"
    return 1
  }
  local d
  for d in "${GENERATED_DEPS[@]}"; do
    if [ -e "$d" ]; then
      say "  REFUSE: generated dependency still present (deps-plan + external rebuild, then remove): $d"
      return 1
    fi
  done
  say "  broker marker: $(cat "$BROKER_MARKER")"
  return 0
}

# chown/chmod one tree; skip hardlinked files (nlink>1) — report them
_switch_tree(){
  local p="$1"
  say "  --- tree $p"
  local skipped=0
  # dirs (no follow symlinks)
  run find -P "$p" -path "$p/.git" -prune -o -type d -exec chown "$BROKER_USER:$HUMAN_GROUP" {} + -exec chmod 2750 {} +
  # executable files: nlink==1 only
  while IFS= read -r -d '' f; do
    if [ "$(stat -c '%h' "$f")" -gt 1 ]; then
      say "    SKIP_HARDLINK_EXEC $f"; skipped=$((skipped+1)); continue
    fi
    run chown "$BROKER_USER:$HUMAN_GROUP" "$f"
    run chmod 0750 "$f"
  done < <(find -P "$p" -path "$p/.git" -prune -o -type f -perm -u+x -print0 2>/dev/null)
  # non-executable files: nlink==1 only
  while IFS= read -r -d '' f; do
    if [ "$(stat -c '%h' "$f")" -gt 1 ]; then
      say "    SKIP_HARDLINK_FILE $f"; skipped=$((skipped+1)); continue
    fi
    run chown "$BROKER_USER:$HUMAN_GROUP" "$f"
    run chmod 0640 "$f"
  done < <(find -P "$p" -path "$p/.git" -prune -o -type f ! -perm -u+x -print0 2>/dev/null)
  if [ -e "$p/.git" ]; then
    run find -P "$p/.git" -type d -exec chown "$BROKER_USER:$BROKER_GROUP" {} + -exec chmod 2700 {} +
    while IFS= read -r -d '' f; do
      if [ "$(stat -c '%h' "$f")" -gt 1 ]; then
        say "    SKIP_HARDLINK_GIT $f"; skipped=$((skipped+1)); continue
      fi
      run chown "$BROKER_USER:$BROKER_GROUP" "$f"
      run chmod 0600 "$f"
    done < <(find -P "$p/.git" -type f -print0 2>/dev/null)
  fi
  say "  HARD_LINK_SKIPPED=$skipped"
}

switch(){
  phase "switch"
  if [ "$MODE" = plan ]; then
    say "  (plan) switch would require:"
    switch_preconditions || true
    say "  SCOPE=only three formal trees (no Projects/AppProjects chattr/chown)"
    say "  PARENT_RENAME_PROTECTION=UNRESOLVED"
    say "  -> apply is NOT runnable from plan mode."
    return 0
  fi
  [ "$(id -u)" = 0 ] || stop need_root "switch requires root"
  require_commit
  # Mandatory throwaway preflight before any formal permission change
  switch_preflight || stop switch_preflight_failed "throwaway preflight failed"
  trap - EXIT
  switch_preconditions || stop switch_preconditions "preconditions unmet"
  say "  no fake revert; on failure STOP_AT names the precise phase."
  local p
  for p in "${PROJECTS[@]}"; do
    PHASE="switch_tree:$(basename "$p")"
    _switch_tree "$p"
  done
  for p in "${BUSINESS_PROJECTS[@]}"; do
    [ -e "$p" ] || stop keeplab_missing "business project missing: $p"
    PHASE="switch_tree:$(basename "$p")"
    _switch_tree "$p"
  done
  # Re-install promote ACL from this tip so broker CAS still works post-chown
  PHASE="switch_acl_aegl"
  git -C "$AEGL_ROOT" show "$COMMIT:recovery/install-promote-target-acl.sh" \
    | bash -s -- --repo "$AEGL_ROOT" --project "$AEGL_DEFAULT" --commit "$COMMIT" \
         --target-ref refs/heads/main \
    || stop switch_acl_aegl "ACL reinstall AEGL failed"
  PHASE="switch_acl_stack"
  git -C "$AEGL_ROOT" show "$COMMIT:recovery/install-promote-target-acl.sh" \
    | bash -s -- --repo "$AEGL_ROOT" --project "$STACK_DEFAULT" --commit "$COMMIT" \
         --target-ref refs/heads/master \
    || stop switch_acl_stack "ACL reinstall Stack failed"
  PHASE="switch_acl_keeplab"
  git -C "$AEGL_ROOT" show "$COMMIT:recovery/install-promote-target-acl.sh" \
    | bash -s -- --repo "$AEGL_ROOT" --project "$KEEPLAB_DEFAULT" --commit "$COMMIT" \
         --target-ref refs/heads/master --business-root "$BUSINESS_PARENT" \
    || stop switch_acl_keeplab "ACL reinstall KeepLab failed"

  say "  HOME traverse for broker: setfacl --x on $HOME_DIR (needed for absolute paths)"
  run setfacl -m "u:$BROKER_USER:--x" "$HOME_DIR"
  say "  PARENT_RENAME_PROTECTION=UNRESOLVED — did NOT chown/chattr $PROJECTS_PARENT or $BUSINESS_PARENT"
  say "  LOGIN_GROUP_NOTE: refresh zhong session for $HUMAN_GROUP read access if newly added"
  say "SWITCH_RESULT=OK"
  say "  next: git show $COMMIT:recovery/host-identity-bootstrap.sh | sudo bash -s -- --commit $COMMIT verify"
}

# --------------------------------------------------------------------------- #
# selftest (isolated)
# --------------------------------------------------------------------------- #
selftest(){
  phase "selftest"
  local ST fails=0
  ST="$(mktemp -d /var/tmp/aegl-selftest-XXXXXX)" || stop mktemp_failed "mktemp"
  mkdir -p "$ST/A/Demo/sub" "$ST/A/Demo/.git"
  echo x > "$ST/A/Demo/sub/f.txt"; echo c > "$ST/A/Demo/.git/config"
  VFAIL=0
  check "A operator write root" ok "$OPERATOR_USER" "$ST/A/Demo" || true
  # Expect violations when we want "no" on a writable tree
  VFAIL=0
  check "A expect deny (should fail count)" no "$OPERATOR_USER" "$ST/A/Demo"
  [ "$VFAIL" -gt 0 ] && say "  PASS A: writable tree reports violations" || { say "  FAIL A"; fails=$((fails+1)); }
  mkdir -p "$ST/B/Demo/sub" "$ST/B/Demo/.git"
  echo x > "$ST/B/Demo/sub/f.txt"; echo c > "$ST/B/Demo/.git/config"
  chmod -R a-w "$ST/B/Demo" 2>/dev/null || true
  chmod a-w "$ST/B" 2>/dev/null || true
  VFAIL=0
  check "B operator cannot write root"   no "$OPERATOR_USER" "$ST/B/Demo"
  check "B operator cannot write nested" no "$OPERATOR_USER" "$ST/B/Demo/sub/f.txt"
  check "B operator cannot write .git"   no "$OPERATOR_USER" "$ST/B/Demo/.git/config"
  [ "$VFAIL" -eq 0 ] && say "  PASS B: mode-protected denies operator" || { say "  FAIL B: $VFAIL"; fails=$((fails+1)); }
  if ( touch "$ST/B/Demo/sub/probe-$$" ) 2>/dev/null; then say "  FAIL B: write succeeded"; fails=$((fails+1)); else say "  PASS B: write denied"; fi
  chmod -R u+w "$ST" 2>/dev/null || true
  rm -rf "$ST"
  [ "$fails" -eq 0 ] || stop selftest_failed "failures=$fails"
  say "SELFTEST_RESULT=OK"
}

broker_install_plan(){
  phase "broker-plan (print only; does not install or write marker)"
  say "Broker already installed and matched tip files in this environment when broker-bind passes."
  say "Do NOT reinstall or re-run full broker/model acceptance."
  say "Bind marker after tip match:"
  say "  git -C $AEGL_DEFAULT show <TIP>:recovery/host-identity-bootstrap.sh \\"
  say "    | sudo bash -s -- --commit <TIP> --aegl $AEGL_DEFAULT broker-bind --write-marker"
}

main(){
  say "AEGL host identity bootstrap  [mode=$MODE aegl=$AEGL_ROOT commit=${COMMIT:-none}]"
  case "$MODE" in
    plan)
      preflight_paths
      list_generated_deps
      say ""
      prepare
      switch
      say ""
      say "NOTE: switch refuses until broker-bind marker + deps removed."
      say "PARENT_RENAME_PROTECTION=UNRESOLVED"
      say "AI_BOUNDARY=PREP_READY_NOT_SWITCHED"
      ;;
    prepare) prepare ;;
    deps-plan) list_generated_deps ;;
    broker-bind) broker_bind ;;
    switch-preflight) require_commit; switch_preflight ;;
    switch) switch ;;
    verify) do_verify ;;
    selftest) selftest ;;
    broker-plan) broker_install_plan ;;
    *) stop bad_mode "unknown mode $MODE" ;;
  esac
  say "STOP_AT=complete mode=$MODE"
}
main
