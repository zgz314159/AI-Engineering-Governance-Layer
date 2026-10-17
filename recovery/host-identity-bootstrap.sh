#!/usr/bin/env bash
# host-identity-bootstrap.sh — AEGL host identity prepare / switch / verify.
#
# Trusted delivery (fixed full SHA; works when piped — never requires BASH_SOURCE):
#   git -C "$AEGL" show "$TIP:recovery/host-identity-bootstrap.sh" \
#     | sudo bash -s -- --commit "$TIP" --aegl "$AEGL" <mode>
#
# Modes: plan|prepare|deps-plan|deps-wire|broker-bind|switch-preflight|switch|verify|selftest|broker-plan
#
# Failures stop immediately with STOP_AT=<phase>.
set -euo pipefail

COMMIT=""; AEGL_ARG=""; MODE=""; WRITE_MARKER=0; SKIP_PREFLIGHT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --commit) COMMIT="${2:-}"; shift 2 ;;
    --aegl) AEGL_ARG="${2:-}"; shift 2 ;;
    --write-marker) WRITE_MARKER=1; shift ;;
    --skip-preflight) SKIP_PREFLIGHT=1; shift ;;
    plan|prepare|switch|verify|selftest|broker-plan|broker-bind|deps-plan|deps-wire|switch-preflight)
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
BROKER_REG="/var/lib/aegl-promote/registry.json"

HOME_DIR="/home/zhong"
PROJECTS_PARENT="/home/zhong/Projects"
BUSINESS_PARENT="/home/zhong/AppProjects"
AEGL_DEFAULT="$PROJECTS_PARENT/AI-Engineering-Governance-Layer"
STACK_DEFAULT="$PROJECTS_PARENT/Google-Android-Agent-Development-Stack"
KEEPLAB_DEFAULT="$BUSINESS_PARENT/KeepLab-Relay"
GUARD_SRC="$STACK_DEFAULT/orchestration/hermes/evaluation_adapter/contract_guard.py"

if [ -n "$AEGL_ARG" ]; then
  AEGL_ROOT="$(cd "$AEGL_ARG" && pwd)"
elif [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  AEGL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
else
  AEGL_ROOT="$AEGL_DEFAULT"
fi

PROJECTS=( "$AEGL_DEFAULT" "$STACK_DEFAULT" )
BUSINESS_PROJECTS=( "$KEEPLAB_DEFAULT" )

GENERATED_DEPS=(
  "$AEGL_DEFAULT/fixture/.specify/extensions/architecture-guard/node_modules"
  "$AEGL_DEFAULT/upstream/rulesync/node_modules"
)
RULESYNC_PKG="$AEGL_DEFAULT/upstream/rulesync"
ARCHGUARD_PKG="$AEGL_DEFAULT/fixture/.specify/extensions/architecture-guard"

# Production root (root-owned). Non-root deps-wire uses operator stage.
EXTERNAL_DEP_ROOT="/var/lib/aegl/rebuildable-deps"
DEPS_STAGE_DEFAULT="/home/zhong/.local/state/aegl/rebuildable-deps-stage"
DEPS_ENV_PROD="/etc/aegl/rebuildable-deps.env"
PNPM_STORE_DEFAULT="${PNPM_STORE:-$HOME/.local/share/pnpm/store/v11}"

PHASE="init"
SWITCH_PREFLIGHT_DONE=0
# Global for EXIT cleanup (must not close over function locals).
PF_ST=""

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

# Live execute for prepare / switch / switch-preflight / deps-wire
run(){
  printf '  $ %s\n' "$*"
  case "$MODE" in
    prepare|switch|switch-preflight|deps-wire)
      "$@" || stop "run_failed_$PHASE" "command failed: $*" ;;
  esac
}

as_user_test_w(){
  local user="$1" path="$2"
  if [ "$(id -u)" = 0 ]; then
    runuser -u "$user" -- bash --noprofile --norc -c 'builtin test -w "$1"' _ "$path"
  else
    bash --noprofile --norc -c 'builtin test -w "$1"' _ "$path"
  fi
}
as_user_test_r(){
  local user="$1" path="$2"
  if [ "$(id -u)" = 0 ]; then
    runuser -u "$user" -- bash --noprofile --norc -c 'builtin test -r "$1"' _ "$path"
  else
    bash --noprofile --norc -c 'builtin test -r "$1"' _ "$path"
  fi
}

preflight_paths(){
  local p
  for p in "${PROJECTS[@]}" "${BUSINESS_PROJECTS[@]}" "$PROJECTS_PARENT" "$BUSINESS_PARENT" "$HOME_DIR"; do
    if [ ! -e "$p" ]; then stop path_missing "manifest path missing: $p"; fi
    if [ -L "$p" ]; then stop path_symlink "manifest path is a symlink: $p"; fi
  done
  return 0
}

# Explicit host identity prep (may create aegl-ro). Not "zero host change".
prepare_host_identities(){
  phase "host-identity-prep (accounts/groups; before formal project chown)"
  getent group "$AI_GROUP"     >/dev/null || run groupadd --system "$AI_GROUP"
  getent group "$BROKER_GROUP" >/dev/null || run groupadd --system "$BROKER_GROUP"
  getent group "$HUMAN_GROUP"  >/dev/null || run groupadd --system "$HUMAN_GROUP"
  id "$AI_USER"     >/dev/null 2>&1 || run useradd --system --no-create-home --shell /usr/sbin/nologin --gid "$AI_GROUP" "$AI_USER"
  id "$BROKER_USER" >/dev/null 2>&1 || run useradd --system --no-create-home --shell /usr/sbin/nologin --gid "$BROKER_GROUP" "$BROKER_USER"
  run usermod -aG "$HUMAN_GROUP" "$OPERATOR_USER"
  run install -d -o "$AI_USER" -g "$BROKER_GROUP" -m 2770 "$AI_STATE_ROOT"
  say "  HOST_PREP_NOTE: aegl-ro/usermod are intentional host changes; not claimed as zero-change"
  say "  LOGIN_GROUP_NOTE: refresh $OPERATOR_USER session (newgrp $HUMAN_GROUP or re-login) for group read"
  say "HOST_IDENTITY_PREP_RESULT=OK"
}

prepare(){
  phase "prepare"
  preflight_paths
  prepare_host_identities
  say "PREPARE_RESULT=OK"
}

# --------------------------------------------------------------------------- #
# deps — freeze, wire (install+entries), delete prep (no formal delete)
# --------------------------------------------------------------------------- #
_deps_root(){
  if [ "$(id -u)" = 0 ]; then printf '%s\n' "$EXTERNAL_DEP_ROOT"
  else printf '%s\n' "${AEGL_DEPS_STAGE:-$DEPS_STAGE_DEFAULT}"; fi
}

_owning_repo_tracked_under(){
  # Args: package_dir relative_path_inside — check owning git repo, not parent AEGL.
  # stdout = count only (or -1); diagnostics on stderr.
  local pkg="$1" rel="${2:-.}"
  local git_dir
  if [ -f "$pkg/.git" ]; then
    git_dir="$(sed -n 's/^gitdir: //p' "$pkg/.git")"
    if [ -n "$git_dir" ] && [ ! -d "$pkg/$git_dir" ] && [ ! -d "$git_dir" ]; then
      printf '    OWNING_GIT=broken_gitfile path=%s/.git -> %s\n' "$pkg" "$git_dir" >&2
      printf '%s\n' "-1"
      return 0
    fi
  fi
  if git -C "$pkg" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$pkg" ls-files -- "$rel" 2>/dev/null | wc -l
  else
    printf '    OWNING_GIT=not_a_repo path=%s\n' "$pkg" >&2
    printf '%s\n' "-1"
  fi
}

list_generated_deps(){
  phase "deps-plan (freeze + owning-repo source check; nothing deleted)"
  local d tracked_parent tracked_own
  for d in "${GENERATED_DEPS[@]}"; do
    if [ ! -e "$d" ]; then say "  (absent) $d"; continue; fi
    local pkg sz nf nlink_gt1
    case "$d" in
      */rulesync/node_modules) pkg="$RULESYNC_PKG" ;;
      */architecture-guard/node_modules) pkg="$ARCHGUARD_PKG" ;;
      *) pkg="$(dirname "$d")" ;;
    esac
    sz="$(du -sh "$d" 2>/dev/null | cut -f1)"
    nf="$(find -P "$d" -type f 2>/dev/null | wc -l)"
    nlink_gt1="$(find -P "$d" -type f -links +1 2>/dev/null | wc -l)"
    tracked_parent="$(git -C "$AEGL_DEFAULT" ls-files -- "${d#"$AEGL_DEFAULT/"}" 2>/dev/null | wc -l)"
    tracked_own="$(_owning_repo_tracked_under "$pkg" "node_modules")"
    say "  FREEZE_PATH=$d"
    say "    size=$sz files=$nf parent_ls_files=$tracked_parent owning_repo_node_modules_ls_files=$tracked_own hardlinks_gt1=$nlink_gt1"
    if [ "$tracked_own" = "0" ]; then
      say "    unique_source_in_node_modules=no (owning repo ignores regenerable deps)"
    elif [ "$tracked_own" = "-1" ]; then
      say "    unique_source=UNKNOWN (owning git unavailable — do not claim zero unique source from parent alone)"
    else
      say "    unique_source=YES count=$tracked_own — REFUSE delete until reviewed"
    fi
  done
  say "  EXTERNAL_DEP_ROOT=$EXTERNAL_DEP_ROOT"
  say "  DEPS_STAGE_DEFAULT=$DEPS_STAGE_DEFAULT"
  say "  NEXT=deps-wire (install+entry checks); formal delete NOT this mode"
  say "  DEPS_PLAN_OK=1"
}

deps_wire(){
  phase "deps-wire (external install + entry checks; no in-tree delete)"
  local root store lock_rs lock_ag ver_rs ver_ag
  root="$(_deps_root)"
  store="$PNPM_STORE_DEFAULT"
  command -v pnpm >/dev/null 2>&1 || stop deps_no_pnpm "pnpm required for deps-wire"
  command -v rsync >/dev/null 2>&1 || stop deps_no_rsync "rsync required for deps-wire"
  [ -f "$RULESYNC_PKG/pnpm-lock.yaml" ] || stop deps_lock_missing "rulesync lock missing"
  [ -f "$ARCHGUARD_PKG/pnpm-lock.yaml" ] || stop deps_lock_missing "architecture-guard lock missing"
  [ -d "$store" ] || stop deps_store_missing "pnpm store missing: $store"

  ver_rs="$(python3 -c 'import json;print(json.load(open("'"$RULESYNC_PKG"'/package.json"))["version"])')"
  ver_ag="$(python3 -c 'import json;print(json.load(open("'"$ARCHGUARD_PKG"'/package.json"))["version"])')"
  lock_rs="$(sha256sum "$RULESYNC_PKG/pnpm-lock.yaml" | awk '{print $1}')"
  lock_ag="$(sha256sum "$ARCHGUARD_PKG/pnpm-lock.yaml" | awk '{print $1}')"
  say "  DEPS_ROOT=$root (root→$EXTERNAL_DEP_ROOT; non-root→stage)"
  say "  RULESYNC version=$ver_rs lock_sha256=$lock_rs"
  say "  ARCHGUARD version=$ver_ag lock_sha256=$lock_ag"

  local own_rs own_ag
  own_rs="$(_owning_repo_tracked_under "$RULESYNC_PKG" "node_modules")"
  own_ag="$(_owning_repo_tracked_under "$ARCHGUARD_PKG" "node_modules")"
  [ "$own_rs" = "0" ] || stop deps_unique_rulesync "rulesync owning-repo tracks node_modules files=$own_rs"
  # fixture architecture-guard may have a broken gitfile; require upstream submodule = 0.
  if [ "$own_ag" != "0" ] && [ "$own_ag" != "-1" ]; then
    stop deps_unique_archguard "architecture-guard owning-repo tracks node_modules files=$own_ag"
  fi
  if [ ! -d "$AEGL_DEFAULT/upstream/architecture-guard" ]; then
    stop deps_archguard_upstream "upstream/architecture-guard missing for owning-repo check"
  fi
  local own_uag
  own_uag="$(_owning_repo_tracked_under "$AEGL_DEFAULT/upstream/architecture-guard" "node_modules")"
  say "  UPSTREAM_ARCHGUARD_node_modules_ls_files=$own_uag"
  [ "$own_uag" = "0" ] || stop deps_unique_archguard_upstream "upstream architecture-guard tracks node_modules files=$own_uag"

  run mkdir -p "$root/rulesync" "$root/architecture-guard" "$root/bin"
  run rsync -a --delete --exclude node_modules --exclude .git \
    "$RULESYNC_PKG/" "$root/rulesync/"
  run rsync -a --delete --exclude node_modules --exclude .git \
    "$ARCHGUARD_PKG/" "$root/architecture-guard/"

  export CI=1
  (
    cd "$root/rulesync"
    pnpm install --frozen-lockfile --ignore-scripts --store-dir "$store" --prefer-offline
  ) || stop deps_install_rulesync "rulesync external pnpm install failed"
  (
    cd "$root/architecture-guard"
    pnpm install --frozen-lockfile --ignore-scripts --store-dir "$store" --prefer-offline
  ) || stop deps_install_archguard "architecture-guard external pnpm install failed"

  [ "$(sha256sum "$root/rulesync/pnpm-lock.yaml" | awk '{print $1}')" = "$lock_rs" ] \
    || stop deps_lock_drift_rulesync "staged rulesync lock drifted"
  [ "$(sha256sum "$root/architecture-guard/pnpm-lock.yaml" | awk '{print $1}')" = "$lock_ag" ] \
    || stop deps_lock_drift_archguard "staged architecture-guard lock drifted"

  [ -f "$root/rulesync/dist/cli/index.js" ] || stop deps_rulesync_dist "rulesync dist missing in external root"
  if [ ! -f "$root/architecture-guard/dist/bin/cli.js" ]; then
    ( cd "$root/architecture-guard" && pnpm exec tsc ) \
      || stop deps_archguard_build "architecture-guard tsc failed in external root"
  fi
  [ -f "$root/architecture-guard/dist/bin/cli.js" ] || stop deps_archguard_dist "architecture-guard dist missing"

  # Entry wrappers (real paths — not NODE_PATH-only).
  cat > "$root/bin/rulesync" <<EOF
#!/usr/bin/env bash
exec node "$root/rulesync/dist/cli/index.js" "\$@"
EOF
  cat > "$root/bin/architecture-guard" <<EOF
#!/usr/bin/env bash
exec node "$root/architecture-guard/dist/bin/cli.js" "\$@"
EOF
  chmod 0755 "$root/bin/rulesync" "$root/bin/architecture-guard"

  # Point entry checks from external tree
  "$root/bin/rulesync" --help >/dev/null \
    || stop deps_entry_rulesync_help "external rulesync --help failed"
  ( cd "$AEGL_DEFAULT/fixture" && "$root/bin/rulesync" generate --targets claudecode --features rules --check ) \
    || stop deps_entry_rulesync_generate "external rulesync generate --check failed"
  "$root/bin/architecture-guard" --help >/dev/null \
    || stop deps_entry_archguard_help "external architecture-guard --help failed"
  say "  ENTRY_CHECK rulesync=OK architecture-guard=OK"

  local envfile manifest
  if [ "$(id -u)" = 0 ]; then
    envfile="$DEPS_ENV_PROD"
    mkdir -p "$(dirname "$envfile")"
  else
    envfile="$root/rebuildable-deps.env"
  fi
  cat > "$envfile" <<EOF
# Generated by host-identity deps-wire — source before doctor/rulesync entries.
AEGL_REBUILDABLE_DEPS_ROOT=$root
AEGL_RULESYNC_CLI=$root/rulesync/dist/cli/index.js
AEGL_ARCHITECTURE_GUARD_CLI=$root/architecture-guard/dist/bin/cli.js
PATH=$root/bin:\$PATH
EOF
  manifest="$root/wire-manifest.txt"
  cat > "$manifest" <<EOF
rulesync_version=$ver_rs
rulesync_lock_sha256=$lock_rs
rulesync_cli=$root/rulesync/dist/cli/index.js
architecture_guard_version=$ver_ag
architecture_guard_lock_sha256=$lock_ag
architecture_guard_cli=$root/architecture-guard/dist/bin/cli.js
env_file=$envfile
EOF
  say "  WROTE_ENV=$envfile"
  say "  WROTE_MANIFEST=$manifest"
  say "  DOCTOR_HINT=set -a; source $envfile; set +a; then bin/aegl-recovery doctor (uses AEGL_RULESYNC_CLI)"

  say "  DELETE_PREP (NOT executed this round; no backup; no old-path symlink):"
  say "    test -d $root/rulesync/node_modules && test -x $root/bin/rulesync"
  say "    test -d $root/architecture-guard/node_modules && test -x $root/bin/architecture-guard"
  say "    source $envfile && (cd $AEGL_DEFAULT/fixture && node \"\$AEGL_RULESYNC_CLI\" generate --targets claudecode --features rules --check)"
  for d in "${GENERATED_DEPS[@]}"; do
    say "    # only after checks above:"
    say "    rm -rf -- $(printf '%q' "$d")"
  done
  say "  THIS_ROUND=no formal delete"
  say "DEPS_WIRE_RESULT=OK root=$root"
}

# --------------------------------------------------------------------------- #
# verify
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
  check "zhong cannot write project root"     no "$OPERATOR_USER" "$p"
  check "aegl-ai cannot write project root"   no "$AI_USER" "$p"
  if [ -n "$nested" ]; then
    check "zhong cannot write nested file"    no "$OPERATOR_USER" "$nested"
    check "aegl-ai cannot write nested file"  no "$AI_USER" "$nested"
  fi
  if [ -e "$p/.git/config" ]; then
    check "zhong cannot write .git/config"    no "$OPERATOR_USER" "$p/.git/config"
    check "aegl-ai cannot write .git/config"  no "$AI_USER" "$p/.git/config"
  fi
  check "broker can write project root"       ok "$BROKER_USER" "$p"
  if [ "$(id -u)" = 0 ]; then
    if as_user_test_r "$OPERATOR_USER" "$p"; then say "  zhong can read project root: ok"
    else say "  zhong can read project root: FAIL"; VFAIL=$((VFAIL+1)); fi
  fi
  say "    PARENT_RENAME_PROTECTION=UNRESOLVED"
}
do_verify(){
  phase "verify"
  local p
  for p in "${PROJECTS[@]}" "${BUSINESS_PROJECTS[@]}"; do
    [ -e "$p" ] || stop verify_missing "manifest path missing: $p"
    verify_target "$p"
  done
  if [ -f "$GUARD_SRC" ]; then
    if [ -r "$GUARD_SRC" ]; then
      say "  hermes guard source readable by verifier (root/operator): ok ($GUARD_SRC)"
    else
      say "  hermes guard source readable: FAIL"; VFAIL=$((VFAIL+1))
    fi
    say "  HERMES_RUNTIME_READ=root_bind_mount_in_sandbox (aegl-ai reads bind, not raw 0750 HOME traverse)"
  else
    say "  hermes guard source missing: FAIL"; VFAIL=$((VFAIL+1))
  fi
  say "  VERIFY_VIOLATIONS=$VFAIL"
  [ "$VFAIL" -eq 0 ] || stop verify_failed "VERIFY_VIOLATIONS=$VFAIL"
  say "VERIFY_RESULT=OK"
}

# --------------------------------------------------------------------------- #
# broker-bind — tip match + registry promote evidence (not counts alone)
# --------------------------------------------------------------------------- #
_broker_registry_evidence(){
  # Prints EVIDENCE lines; returns 0 if ≥1 landed promote found.
  local reg="$BROKER_REG"
  if [ "$(id -u)" != 0 ]; then
    say "  REGISTRY_EVIDENCE=NOT_RUN need_root (cannot read $reg)"
    return 1
  fi
  [ -f "$reg" ] || { say "  REGISTRY_EVIDENCE=FAIL missing $reg"; return 1; }
  python3 - "$reg" "$AEGL_DEFAULT" "$STACK_DEFAULT" "$KEEPLAB_DEFAULT" <<'PY'
import json, os, subprocess, sys
reg_path, aegl, stack, keeplab = sys.argv[1:5]
roots = {
    "AI-Engineering-Governance-Layer": (aegl, "refs/heads/main"),
    "Google-Android-Agent-Development-Stack": (stack, "refs/heads/master"),
    "KeepLab-Relay": (keeplab, "refs/heads/master"),
}
with open(reg_path, encoding="utf-8") as f:
    reg = json.load(f)
if not isinstance(reg, dict):
    print("REGISTRY_EVIDENCE=FAIL not_a_dict")
    sys.exit(1)
landed = 0
for tid, e in reg.items():
    if not isinstance(e, dict):
        continue
    proj = e.get("project") or ""
    ref = e.get("target_ref") or ""
    commit = e.get("approved_commit") or ""
    verify = e.get("verify_result") or ""
    base = os.path.basename(proj.rstrip("/")) if isinstance(proj, str) else ""
    if not commit or len(commit) != 40:
        continue
    if verify and verify != "PASS":
        continue
    tip = None
    if base in roots:
        path, want_ref = roots[base]
        if ref and ref != want_ref:
            print("EVIDENCE_SKIP task=%s reason=target_ref_mismatch got=%s want=%s" % (tid, ref, want_ref))
            continue
        try:
            tip = subprocess.check_output(
                ["git", "-C", path, "rev-parse", want_ref], text=True
            ).strip()
        except Exception as exc:
            print("EVIDENCE_SKIP task=%s reason=rev_parse %s" % (tid, exc))
            continue
        # Landed if tip equals approved, or approved is ancestor of tip (later promotes).
        if tip == commit:
            result = "LANDED_EXACT"
        else:
            rc = subprocess.call(
                ["git", "-C", path, "merge-base", "--is-ancestor", commit, tip]
            )
            result = "LANDED_ANCESTOR" if rc == 0 else "NOT_ON_TIP"
        print(
            "EVIDENCE task=%s project=%s target_ref=%s approved_commit=%s verify_result=%s tip_now=%s result=%s"
            % (tid, base, ref or want_ref, commit, verify or "recorded", tip, result)
        )
        if result.startswith("LANDED"):
            landed += 1
    else:
        print(
            "EVIDENCE task=%s project=%s target_ref=%s approved_commit=%s verify_result=%s result=RECORDED_OTHER"
            % (tid, proj, ref, commit, verify or "recorded")
        )
print("REGISTRY_LANDED_PROMOTES=%d" % landed)
sys.exit(0 if landed >= 1 else 1)
PY
}

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
  local biz
  biz="$(grep -E '^Environment=AEGL_BUSINESS_ROOT=' "$BROKER_UNIT" 2>/dev/null || true)"
  [ -n "$biz" ] || stop broker_unit "AEGL_BUSINESS_ROOT missing from $BROKER_UNIT"
  say "  UNIT_BUSINESS_ROOT=$biz"
  say "  FORMAL_TIPS aegl_main=$(git -C "$AEGL_DEFAULT" rev-parse refs/heads/main) stack_master=$(git -C "$STACK_DEFAULT" rev-parse refs/heads/master) keeplab_master=$(git -C "$KEEPLAB_DEFAULT" rev-parse refs/heads/master)"

  local ev_rc=0
  set +e
  _broker_registry_evidence
  ev_rc=$?
  set -e
  if [ "$ev_rc" -ne 0 ]; then
    if [ "$(id -u)" != 0 ]; then
      say "  REGISTRY_EVIDENCE_STATUS=NOT_RUN (non-root)"
    else
      stop broker_evidence "no landed promote evidence in registry (project/ref/commit/result)"
    fi
  else
    say "  REGISTRY_EVIDENCE_STATUS=OK"
  fi

  if [ "$WRITE_MARKER" = 1 ]; then
    [ "$(id -u)" = 0 ] || stop need_root "broker-bind --write-marker requires root"
    [ "$ev_rc" -eq 0 ] || stop broker_evidence "refusing marker without registry promote evidence"
    umask 022
    printf 'broker_verified commit=%s tip_match=1 unit_active=1 registry_landed_promotes=1 aegl_main=%s stack_master=%s keeplab_master=%s ts=%s\n' \
      "$COMMIT" \
      "$(git -C "$AEGL_DEFAULT" rev-parse refs/heads/main)" \
      "$(git -C "$STACK_DEFAULT" rev-parse refs/heads/master)" \
      "$(git -C "$KEEPLAB_DEFAULT" rev-parse refs/heads/master)" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      > "$BROKER_MARKER"
    chown root:root "$BROKER_MARKER"
    chmod 0644 "$BROKER_MARKER"
    say "  WROTE $BROKER_MARKER (evidence=tip_sha256+unit+registry_landed; not a bare touch)"
  else
    say "  MARKER_WRITE=skipped (pass --write-marker as root after registry evidence OK)"
    if [ -f "$BROKER_MARKER" ]; then say "  MARKER_PRESENT=$(cat "$BROKER_MARKER")"; else say "  MARKER_PRESENT=absent"; fi
  fi
  say "BROKER_BIND_RESULT=OK"
}

# --------------------------------------------------------------------------- #
# hardlink gate — refuse before any formal chown
# --------------------------------------------------------------------------- #
scan_unhandled_hardlinks(){
  phase "hardlink-scan (before any formal chown)"
  local p f count=0
  local report
  report="$(mktemp /var/tmp/aegl-hardlink-scan-XXXXXX)" || stop mktemp_failed "hardlink scan"
  for p in "${PROJECTS[@]}" "${BUSINESS_PROJECTS[@]}"; do
    [ -e "$p" ] || continue
    while IFS= read -r -d '' f; do
      # Allow listed generated deps only until deleted — still count them as blockers.
      printf '%s\n' "$f" >> "$report"
      count=$((count+1))
    done < <(find -P "$p" -type f -links +1 -print0 2>/dev/null)
  done
  if [ "$count" -gt 0 ]; then
    say "  UNHANDLED_HARDLINKS=$count (first 40):"
    head -40 "$report" | sed 's/^/    /'
    rm -f "$report"
    stop hardlinks_present "refuse switch: $count hardlinked files would touch shared inodes; remove generated deps / break links first"
  fi
  rm -f "$report"
  say "  HARD_LINK_SCAN=OK count=0"
}

# --------------------------------------------------------------------------- #
# switch tree apply (production function — also used by preflight on throwaway)
# --------------------------------------------------------------------------- #
_switch_tree(){
  local p="$1"
  say "  --- tree $p"
  # Encountering nlink>1 is fatal (scan should have blocked already).
  local f
  while IFS= read -r -d '' f; do
    [ "$(stat -c '%h' "$f")" -eq 1 ] || stop hardlink_during_switch "nlink>1 during switch: $f"
  done < <(find -P "$p" -type f -print0 2>/dev/null)

  run find -P "$p" -path "$p/.git" -prune -o -type d -exec chown "$BROKER_USER:$HUMAN_GROUP" {} + -exec chmod 2750 {} +
  while IFS= read -r -d '' f; do
    run chown "$BROKER_USER:$HUMAN_GROUP" "$f"
    run chmod 0750 "$f"
  done < <(find -P "$p" -path "$p/.git" -prune -o -type f -perm -u+x -print0 2>/dev/null)
  while IFS= read -r -d '' f; do
    run chown "$BROKER_USER:$HUMAN_GROUP" "$f"
    run chmod 0640 "$f"
  done < <(find -P "$p" -path "$p/.git" -prune -o -type f ! -perm -u+x -print0 2>/dev/null)
  if [ -e "$p/.git" ]; then
    run find -P "$p/.git" -type d -exec chown "$BROKER_USER:$BROKER_GROUP" {} + -exec chmod 2700 {} +
    while IFS= read -r -d '' f; do
      run chown "$BROKER_USER:$BROKER_GROUP" "$f"
      run chmod 0600 "$f"
    done < <(find -P "$p/.git" -type f -print0 2>/dev/null)
  fi
}

_install_post_switch_acl(){
  local proj="$1" target_ref="$2"
  local extra=()
  if [ "$proj" = "$KEEPLAB_DEFAULT" ]; then
    extra=(--business-root "$BUSINESS_PARENT")
  fi
  git -C "$AEGL_ROOT" show "$COMMIT:recovery/install-promote-target-acl.sh" \
    | bash -s -- --repo "$AEGL_ROOT" --project "$proj" --commit "$COMMIT" \
         --target-ref "$target_ref" --post-owner-switch "${extra[@]}" \
    || stop switch_acl "ACL post-owner-switch failed for $proj"
}

# --------------------------------------------------------------------------- #
# switch-preflight — one throwaway repo: real _switch_tree + CAS + broker sync
# --------------------------------------------------------------------------- #
_cleanup_pf(){
  local st="${PF_ST:-}"
  if [ -n "$st" ] && [ -d "$st" ]; then
    chmod -R u+w "$st" 2>/dev/null || true
    rm -rf "$st"
  fi
  PF_ST=""
}

switch_preflight(){
  phase "switch-preflight"
  if [ "$SWITCH_PREFLIGHT_DONE" = 1 ]; then
    say "SWITCH_PREFLIGHT=SKIP already_done_this_process"
    return 0
  fi
  if [ "$(id -u)" != 0 ]; then
    say "SWITCH_PREFLIGHT=NOT_RUN need_root (not faking cross-UID PASS)"
    return 0
  fi
  require_commit
  command -v setfacl >/dev/null 2>&1 || stop missing_setfacl "setfacl required"

  # May create aegl-ro — explicit host prep before any formal project chown.
  prepare_host_identities
  id "$BROKER_USER" >/dev/null 2>&1 || stop missing_broker_user "$BROKER_USER"
  id "$OPERATOR_USER" >/dev/null 2>&1 || stop missing_op "$OPERATOR_USER"
  id "$AI_USER" >/dev/null 2>&1 || stop missing_ai "$AI_USER"
  getent group "$HUMAN_GROUP" >/dev/null || stop missing_human_group "$HUMAN_GROUP not created"

  PF_ST="$(mktemp -d /var/tmp/aegl-host-switch-pf-XXXXXX)" || stop mktemp_failed "mktemp"
  trap _cleanup_pf EXIT
  chmod 0755 "$PF_ST"
  # Exact access for test identities (root-created dir).
  setfacl -m "u:${OPERATOR_USER}:rwx" "$PF_ST"
  setfacl -m "u:${BROKER_USER}:rwx" "$PF_ST"
  setfacl -m "u:${AI_USER}:r-x" "$PF_ST"
  setfacl -d -m "u:${OPERATOR_USER}:rwx" "$PF_ST" 2>/dev/null || true
  setfacl -d -m "u:${BROKER_USER}:rwx" "$PF_ST" 2>/dev/null || true

  # Single allowlisted throwaway git repo (same tree for switch + CAS + sync).
  local GREPO="$PF_ST/AI-Engineering-Governance-Layer"
  runuser -u "$OPERATOR_USER" -- git init -q "$GREPO"
  runuser -u "$OPERATOR_USER" -- bash -c "printf 'a\n' > '$GREPO/body.txt'; mkdir -p '$GREPO/sub'; printf 's\n' > '$GREPO/sub/f.txt'"
  runuser -u "$OPERATOR_USER" -- git -C "$GREPO" add -A
  runuser -u "$OPERATOR_USER" -- git -C "$GREPO" -c user.email=t@t -c user.name=t commit -qm a
  runuser -u "$OPERATOR_USER" -- git -C "$GREPO" branch -M main
  local V1 V2
  V1="$(runuser -u "$OPERATOR_USER" -- git -C "$GREPO" rev-parse HEAD)"
  runuser -u "$OPERATOR_USER" -- git -C "$GREPO" checkout -q -b cand
  runuser -u "$OPERATOR_USER" -- bash -c "printf 'b\n' > '$GREPO/body.txt'"
  runuser -u "$OPERATOR_USER" -- git -C "$GREPO" add -A
  runuser -u "$OPERATOR_USER" -- git -C "$GREPO" -c user.email=t@t -c user.name=t commit -qm b
  V2="$(runuser -u "$OPERATOR_USER" -- git -C "$GREPO" rev-parse HEAD)"
  runuser -u "$OPERATOR_USER" -- git -C "$GREPO" checkout -q main

  as_user_test_w "$OPERATOR_USER" "$GREPO/body.txt" \
    || stop preflight_before "operator should write before switch"
  say "  BEFORE_WRITE=ok"

  # Production switch function on this same repo.
  _switch_tree "$GREPO"

  if as_user_test_w "$OPERATOR_USER" "$GREPO/body.txt"; then
    stop preflight_after_zhong "zhong still can write body after _switch_tree"
  fi
  if as_user_test_w "$OPERATOR_USER" "$GREPO/sub/f.txt"; then
    stop preflight_after_zhong_nested "zhong still can write nested after _switch_tree"
  fi
  if as_user_test_w "$OPERATOR_USER" "$GREPO/.git/config"; then
    stop preflight_after_zhong_git "zhong still can write .git/config"
  fi
  say "  AFTER_ZHONG_WRITE=denied"
  if as_user_test_w "$AI_USER" "$GREPO/body.txt"; then
    stop preflight_after_ai "aegl-ai can write body after _switch_tree"
  fi
  if as_user_test_w "$AI_USER" "$GREPO/.git/config"; then
    stop preflight_after_ai_git "aegl-ai can write .git/config"
  fi
  say "  AFTER_AI_WRITE=denied"
  as_user_test_w "$BROKER_USER" "$GREPO" \
    || stop preflight_broker_root "broker cannot write project root after _switch_tree"
  as_user_test_w "$BROKER_USER" "$GREPO/body.txt" \
    || stop preflight_broker_body "broker cannot write body after _switch_tree (sync needs owner write)"
  say "  AFTER_BROKER_WRITE=ok"

  # Post-owner ACL (does not forbid broker body write).
  _install_post_switch_acl "$GREPO" "refs/heads/main"

  local body_before body_after
  body_before="$(runuser -u "$BROKER_USER" -- cat "$GREPO/body.txt")"
  [ "$body_before" = "a" ] || stop preflight_body "expected body a before CAS"
  runuser -u "$BROKER_USER" -- git \
    -c "safe.directory=$GREPO" -c "core.hooksPath=/dev/null" \
    -c "core.fsmonitor=false" -c "core.attributesFile=/dev/null" \
    -C "$GREPO" update-ref refs/heads/main "$V2" "$V1" \
    || stop preflight_cas "broker update-ref CAS failed"
  [ "$(runuser -u "$BROKER_USER" -- git -c "safe.directory=$GREPO" -C "$GREPO" rev-parse refs/heads/main)" = "$V2" ] \
    || stop preflight_ref "ref not at V2"
  body_after="$(runuser -u "$BROKER_USER" -- cat "$GREPO/body.txt")"
  [ "$body_after" = "a" ] || stop preflight_cas_body "CAS unexpectedly changed worktree"

  # Sync as broker (trusted identity) — not zhong (lost git write).
  runuser -u "$BROKER_USER" -- git \
    -c "safe.directory=$GREPO" -c "core.hooksPath=/dev/null" \
    -c "core.fsmonitor=false" -c "core.attributesFile=/dev/null" \
    -C "$GREPO" restore --source=HEAD --staged --worktree -- . \
    || stop preflight_sync "broker restore/sync failed"
  [ "$(runuser -u "$BROKER_USER" -- cat "$GREPO/body.txt")" = "b" ] \
    || stop preflight_sync_body "broker sync did not land tip body"

  _cleanup_pf
  trap - EXIT
  SWITCH_PREFLIGHT_DONE=1
  say "SWITCH_PREFLIGHT_RESULT=OK"
}

switch_preconditions(){
  [ -f "$BROKER_MARKER" ] || {
    say "  REFUSE: broker not verified ($BROKER_MARKER absent)"
    return 1
  }
  local d
  for d in "${GENERATED_DEPS[@]}"; do
    if [ -e "$d" ]; then
      say "  REFUSE: generated dependency still present: $d"
      return 1
    fi
  done
  local root envf
  root="$EXTERNAL_DEP_ROOT"
  envf="$DEPS_ENV_PROD"
  if [ ! -f "$envf" ] || [ ! -x "$root/bin/rulesync" ]; then
    say "  REFUSE: external deps not wired at $root (run deps-wire as root first)"
    return 1
  fi
  say "  broker marker: $(cat "$BROKER_MARKER")"
  return 0
}

switch(){
  phase "switch"
  if [ "$MODE" = plan ]; then
    say "  (plan) switch would require:"
    switch_preconditions || true
    say "  SCOPE=only three formal trees"
    say "  PARENT_RENAME_PROTECTION=UNRESOLVED"
    say "  -> apply is NOT runnable from plan mode."
    return 0
  fi
  [ "$(id -u)" = 0 ] || stop need_root "switch requires root"
  require_commit
  if [ "$SKIP_PREFLIGHT" = 1 ]; then
    say "  switch-preflight skipped (--skip-preflight; already run this exec)"
    SWITCH_PREFLIGHT_DONE=1
  elif [ "$SWITCH_PREFLIGHT_DONE" = 1 ]; then
    say "  switch-preflight skipped (already_done_this_process)"
  else
    switch_preflight || stop switch_preflight_failed "throwaway preflight failed"
  fi
  switch_preconditions || stop switch_preconditions "preconditions unmet"
  scan_unhandled_hardlinks

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

  PHASE="switch_acl_aegl"
  _install_post_switch_acl "$AEGL_DEFAULT" "refs/heads/main"
  PHASE="switch_acl_stack"
  _install_post_switch_acl "$STACK_DEFAULT" "refs/heads/master"
  PHASE="switch_acl_keeplab"
  _install_post_switch_acl "$KEEPLAB_DEFAULT" "refs/heads/master"

  say "  HOME traverse for broker: setfacl --x on $HOME_DIR"
  run setfacl -m "u:$BROKER_USER:--x" "$HOME_DIR"
  say "  PARENT_RENAME_PROTECTION=UNRESOLVED"
  say "  LOGIN_GROUP_NOTE: refresh zhong session for $HUMAN_GROUP"
  say "SWITCH_RESULT=OK"
}

selftest(){
  phase "selftest"
  local ST fails=0
  ST="$(mktemp -d /var/tmp/aegl-selftest-XXXXXX)" || stop mktemp_failed "mktemp"
  mkdir -p "$ST/A/Demo/sub" "$ST/A/Demo/.git"
  echo x > "$ST/A/Demo/sub/f.txt"; echo c > "$ST/A/Demo/.git/config"
  VFAIL=0
  check "A expect deny (should fail count)" no "$OPERATOR_USER" "$ST/A/Demo"
  [ "$VFAIL" -gt 0 ] && say "  PASS A: writable tree reports violations" || { say "  FAIL A"; fails=$((fails+1)); }
  mkdir -p "$ST/B/Demo/sub" "$ST/B/Demo/.git"
  echo x > "$ST/B/Demo/sub/f.txt"; echo c > "$ST/B/Demo/.git/config"
  chmod -R a-w "$ST/B/Demo" 2>/dev/null || true
  chmod a-w "$ST/B" 2>/dev/null || true
  VFAIL=0
  check "B zhong cannot write root"   no "$OPERATOR_USER" "$ST/B/Demo"
  check "B zhong cannot write nested" no "$OPERATOR_USER" "$ST/B/Demo/sub/f.txt"
  check "B zhong cannot write .git"   no "$OPERATOR_USER" "$ST/B/Demo/.git/config"
  [ "$VFAIL" -eq 0 ] && say "  PASS B: mode-protected denies operator" || { say "  FAIL B: $VFAIL"; fails=$((fails+1)); }
  chmod -R u+w "$ST" 2>/dev/null || true
  rm -rf "$ST"
  [ "$fails" -eq 0 ] || stop selftest_failed "failures=$fails"
  say "SELFTEST_RESULT=OK"
}

broker_install_plan(){
  phase "broker-plan (print only)"
  say "Do NOT reinstall broker. Use broker-bind with registry evidence + --write-marker."
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
      say "NOTE: switch refuses until broker-bind marker + deps-wire + deps removed."
      say "PARENT_RENAME_PROTECTION=UNRESOLVED"
      say "AI_BOUNDARY=PREP_READY_NOT_SWITCHED"
      ;;
    prepare) prepare ;;
    deps-plan) list_generated_deps ;;
    deps-wire) deps_wire ;;
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
