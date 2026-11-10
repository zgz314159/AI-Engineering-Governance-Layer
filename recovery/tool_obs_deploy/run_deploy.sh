#!/usr/bin/env bash
# AEGL-TOOL-OBS-DEPLOY-r1 entry — install-only deployment of four observation files.
#
#   --self-test   ordinary-user package integrity, syntax and simulated install logic.
#                 All install operations run against a temporary fixture target; no
#                 host path is read or written except the package itself.
#   default       root-only real install into /usr/local/lib/aegl-model. It never
#                 starts the launcher and never creates a task scene.
#
# Reused bootstrap: bin/bootstrap.sh (the verified iap_smoke_bootstrap.sh) copies this
# package into a root-exclusive directory, verifies the manifest anchor and then execs
# this entry with any extra arguments.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1

PKG="$(cd "$(dirname "$0")/.." && pwd)"
PINS="$PKG/pins/deploy-pins.sh"

MODE="deploy"
case "${1:-}" in
  --self-test) MODE="self-test" ;;
  "") : ;;
  *) printf 'USAGE: run_smoke.sh [--self-test]\n' >&2; exit 2 ;;
esac

# shellcheck disable=SC1090
. "$PINS"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
notrun() { printf 'NOT_RUN %s\n' "$1"; }
say() { printf '%s\n' "$*"; }

FAIL_STAGE=""
DEPLOY_COMPLETED=()
INSTALLED_ORDER=()
TEMP_PATHS=()

sha() { sha256sum -- "$1" | awk '{print $1}'; }
owner_of() { stat -c '%U:%G' -- "$1"; }
mode_of() { stat -c '%a' -- "$1"; }
is_regular() { [ -f "$1" ] && [ ! -L "$1" ]; }
is_absent() { [ ! -e "$1" ] && [ ! -L "$1" ]; }

package_integrity() {
  local name manifest_sum
  is_regular "$PKG/MANIFEST.sha256" || { FAIL_STAGE=package_manifest_state; return 11; }
  is_regular "$PKG/MANIFEST.sha256.sha256" || { FAIL_STAGE=package_manifest_state; return 11; }
  is_regular "$PINS" || { FAIL_STAGE=package_pins_state; return 12; }
  { [ -d "$PKG/payload" ] && [ ! -L "$PKG/payload" ]; } \
    || { FAIL_STAGE=package_payload_state; return 12; }
  for name in "${PAYLOAD_ORDER[@]}"; do
    is_regular "$PKG/payload/$name" || { FAIL_STAGE=package_payload_state; return 12; }
  done
  ( cd "$PKG" && sha256sum -c --quiet MANIFEST.sha256 ) >/dev/null 2>&1 \
    || { FAIL_STAGE=package_manifest_verify; return 13; }
  manifest_sum="$(awk 'NR==1{print $1}' "$PKG/MANIFEST.sha256.sha256")"
  [ "$manifest_sum" = "$(sha "$PKG/MANIFEST.sha256")" ] \
    || { FAIL_STAGE=package_manifest_anchor; return 14; }
  for name in "${PAYLOAD_ORDER[@]}"; do
    [ "$(sha "$PKG/payload/$name")" = "${PAYLOAD_SHA[$name]}" ] \
      || { FAIL_STAGE=package_payload_hash; return 15; }
  done
  return 0
}

preflight() { # <target>
  local target="$1" name path
  { [ -e "$target" ] && [ -d "$target" ] && [ ! -L "$target" ]; } \
    || { FAIL_STAGE=target_state; return 20; }
  [ "$(owner_of "$target")" = "$TARGET_OWNER" ] || { FAIL_STAGE=target_owner; return 21; }
  [ "$(mode_of "$target")" = "$TARGET_MODE" ] || { FAIL_STAGE=target_mode; return 22; }
  for name in "${NEW_PAYLOADS[@]}"; do
    is_absent "$target/$name" || { FAIL_STAGE=new_target_exists; return 23; }
  done
  for name in "${PAYLOAD_ORDER[@]}"; do
    [ -n "${PAYLOAD_PREDECESSOR[$name]:-}" ] || continue
    path="$target/$name"
    is_regular "$path" || { FAIL_STAGE=predecessor_state; return 24; }
    [ "$(sha "$path")" = "${PAYLOAD_PREDECESSOR[$name]}" ] \
      || { FAIL_STAGE=predecessor_hash; return 25; }
    [ "$(owner_of "$path")" = "${PAYLOAD_OWNER[$name]}" ] \
      || { FAIL_STAGE=predecessor_owner; return 26; }
    [ "$(mode_of "$path")" = "${PAYLOAD_MODE[$name]}" ] \
      || { FAIL_STAGE=predecessor_mode; return 27; }
  done
  for name in "${DEP_ORDER[@]}"; do
    path="$target/$name"
    is_regular "$path" || { FAIL_STAGE=dependency_state; return 30; }
    [ "$(sha "$path")" = "${DEP_SHA[$name]}" ] || { FAIL_STAGE=dependency_hash; return 31; }
    [ "$(owner_of "$path")" = "${DEP_OWNER[$name]}" ] \
      || { FAIL_STAGE=dependency_owner; return 32; }
    [ "$(mode_of "$path")" = "${DEP_MODE[$name]}" ] \
      || { FAIL_STAGE=dependency_mode; return 33; }
  done
  return 0
}

active_run_check() { # [run-root] — 0 clear, 1 active, 2 unknown
  local run_root="${1:-/run/aegl-model}" hits rc=0
  [ -L "$run_root" ] && return 2
  if [ -e "$run_root" ]; then
    { [ -d "$run_root" ] && [ -r "$run_root" ] && [ -x "$run_root" ]; } || return 2
    hits="$(find "$run_root" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" || return 2
    [ -z "$hits" ] || return 1
  fi
  command -v pgrep >/dev/null 2>&1 || return 2
  local pattern
  for pattern in "$DEPLOY_TARGET/(aegl-hermes-sandbox|model_broker[.]py)" \
                 "(^|/)(aegl-hermes-sandbox|model_broker[.]py)([[:space:]]|$)"; do
    rc=0
    hits="$(pgrep -f -a -- "$pattern" 2>/dev/null)" || rc=$?
    if [ "$rc" -eq 0 ]; then
      [ -z "$hits" ] || return 1
    elif [ "$rc" -ne 1 ]; then
      return 2
    fi
  done
  return 0
}

register_temps() { # <target>
  local target="$1" name t stale
  TEMP_PATHS=()
  stale="$(find "$target" -mindepth 1 -maxdepth 1 -name '.aegl-deploy.*' \
            -print -quit 2>/dev/null)" || { FAIL_STAGE=temp_state; return 40; }
  [ -z "$stale" ] || { FAIL_STAGE=temp_conflict; return 41; }
  for name in "${PAYLOAD_ORDER[@]}"; do
    t="$target/.aegl-deploy.$$.$name"
    is_absent "$t" || { FAIL_STAGE=temp_conflict; return 41; }
    TEMP_PATHS+=("$t")
  done
  return 0
}

install_one() { # <target> <name>
  local target="$1" name="$2"
  local src="$PKG/payload/$name"
  local dst="$target/$name"
  local tmp="$target/.aegl-deploy.$$.$name"
  local mode="${PAYLOAD_MODE[$name]}" rc=0 is_new=0 n
  for n in "${NEW_PAYLOADS[@]}"; do [ "$n" = "$name" ] && is_new=1; done
  is_absent "$tmp" || { FAIL_STAGE=temp_state; return 42; }
  is_regular "$src" || { FAIL_STAGE=payload_state; return 43; }
  install -m "$mode" -- "$src" "$tmp" || { rc=$?; FAIL_STAGE="write_$name"; return "$rc"; }
  [ "$(sha "$tmp")" = "${PAYLOAD_SHA[$name]}" ] \
    || { FAIL_STAGE="temp_hash_$name"; return 44; }
  [ "$(owner_of "$tmp")" = "${PAYLOAD_OWNER[$name]}" ] \
    || { FAIL_STAGE="temp_owner_$name"; return 45; }
  [ "$(mode_of "$tmp")" = "$mode" ] || { FAIL_STAGE="temp_mode_$name"; return 46; }
  if [ "$is_new" -eq 1 ]; then
    is_absent "$dst" || { FAIL_STAGE="target_state_$name"; return 47; }
  else
    is_regular "$dst" || { FAIL_STAGE="target_state_$name"; return 47; }
    [ "$(sha "$dst")" = "${PAYLOAD_PREDECESSOR[$name]}" ] \
      || { FAIL_STAGE="target_changed_$name"; return 47; }
    [ "$(owner_of "$dst")" = "${PAYLOAD_OWNER[$name]}" ] \
      || { FAIL_STAGE="target_changed_$name"; return 47; }
    [ "$(mode_of "$dst")" = "${PAYLOAD_MODE[$name]}" ] \
      || { FAIL_STAGE="target_changed_$name"; return 47; }
  fi
  mv -f -- "$tmp" "$dst" || { rc=$?; FAIL_STAGE="rename_$name"; return "$rc"; }
  [ "$(sha "$dst")" = "${PAYLOAD_SHA[$name]}" ] \
    || { FAIL_STAGE="installed_hash_$name"; return 48; }
  [ "$(owner_of "$dst")" = "${PAYLOAD_OWNER[$name]}" ] \
    || { FAIL_STAGE="installed_owner_$name"; return 49; }
  [ "$(mode_of "$dst")" = "$mode" ] || { FAIL_STAGE="installed_mode_$name"; return 50; }
  INSTALLED_ORDER+=("$name")
  return 0
}

install_all() { # <target>
  local target="$1" name
  INSTALLED_ORDER=()
  for name in "${PAYLOAD_ORDER[@]}"; do
    install_one "$target" "$name" || return $?
  done
  return 0
}

post_verify() { # <target>
  local target="$1" name path
  for name in "${PAYLOAD_ORDER[@]}"; do
    path="$target/$name"
    is_regular "$path" || { FAIL_STAGE="verify_payload_state_$name"; return 60; }
    [ "$(sha "$path")" = "${PAYLOAD_SHA[$name]}" ] \
      || { FAIL_STAGE="verify_payload_hash_$name"; return 61; }
    [ "$(owner_of "$path")" = "${PAYLOAD_OWNER[$name]}" ] \
      || { FAIL_STAGE="verify_payload_owner_$name"; return 62; }
    [ "$(mode_of "$path")" = "${PAYLOAD_MODE[$name]}" ] \
      || { FAIL_STAGE="verify_payload_mode_$name"; return 63; }
  done
  for name in "${DEP_ORDER[@]}"; do
    path="$target/$name"
    is_regular "$path" || { FAIL_STAGE="verify_dependency_state_$name"; return 64; }
    [ "$(sha "$path")" = "${DEP_SHA[$name]}" ] \
      || { FAIL_STAGE="verify_dependency_hash_$name"; return 65; }
    [ "$(owner_of "$path")" = "${DEP_OWNER[$name]}" ] \
      || { FAIL_STAGE="verify_dependency_owner_$name"; return 66; }
    [ "$(mode_of "$path")" = "${DEP_MODE[$name]}" ] \
      || { FAIL_STAGE="verify_dependency_mode_$name"; return 67; }
  done
  return 0
}

cleanup_temps() {
  local t
  for t in "${TEMP_PATHS[@]}"; do
    rm -f -- "$t" || { FAIL_STAGE=cleanup; return 70; }
  done
  for t in "${TEMP_PATHS[@]}"; do
    is_absent "$t" || { FAIL_STAGE=cleanup_verify; return 71; }
  done
  return 0
}

deploy_fail() { # <stage> <rc>
  local stage="${1:-UNKNOWN}" rc="${2:-1}"
  [ "$rc" -ne 0 ] || rc=1
  printf 'DEPLOY_FAIL stage=%s rc=%s completed=%s\n' \
    "$stage" "$rc" "${DEPLOY_COMPLETED[*]:-none}"
  exit "$rc"
}

deploy_main() {
  local rc=0 name
  [ "$(id -u)" -eq 0 ] || { printf 'NOT_RUN root_required\n'; exit 1; }

  package_integrity; rc=$?
  [ "$rc" -eq 0 ] || deploy_fail "$FAIL_STAGE" "$rc"
  DEPLOY_COMPLETED+=("package_integrity")

  preflight "$DEPLOY_TARGET"; rc=$?
  [ "$rc" -eq 0 ] || deploy_fail "$FAIL_STAGE" "$rc"
  DEPLOY_COMPLETED+=("preflight")

  active_run_check; rc=$?
  [ "$rc" -eq 0 ] || deploy_fail active_run "$rc"
  DEPLOY_COMPLETED+=("active_run")

  register_temps "$DEPLOY_TARGET"; rc=$?
  [ "$rc" -eq 0 ] || deploy_fail "$FAIL_STAGE" "$rc"
  DEPLOY_COMPLETED+=("temp_register")

  install_all "$DEPLOY_TARGET"; rc=$?
  if [ "$rc" -ne 0 ]; then
    for name in "${INSTALLED_ORDER[@]}"; do DEPLOY_COMPLETED+=("install:$name"); done
    deploy_fail "$FAIL_STAGE" "$rc"
  fi
  for name in "${INSTALLED_ORDER[@]}"; do DEPLOY_COMPLETED+=("install:$name"); done

  post_verify "$DEPLOY_TARGET"; rc=$?
  [ "$rc" -eq 0 ] || deploy_fail "$FAIL_STAGE" "$rc"
  DEPLOY_COMPLETED+=("verify")

  cleanup_temps; rc=$?
  [ "$rc" -eq 0 ] || deploy_fail "$FAIL_STAGE" "$rc"
  DEPLOY_COMPLETED+=("cleanup")

  printf 'DEPLOY_OK target=%s files=%d\n' "$DEPLOY_TARGET" "${#PAYLOAD_ORDER[@]}"
  exit 0
}

# --- ordinary-user checks (simulated install; no host write) ------------------- #
sim_prepare() { # <dir> — fixture target and matching in-memory pins
  local t="$1" name
  rm -rf -- "$t" || return 1
  install -d -m 0755 "$t" "$t/guard" || return 1
  for name in "${DEP_ORDER[@]}"; do
    printf 'dep:%s\n' "$name" > "$t/$name" || return 1
    chmod "${DEP_MODE[$name]}" "$t/$name" || return 1
  done
  printf 'prev:launcher\n' > "$t/aegl-hermes-sandbox" || return 1
  chmod 755 "$t/aegl-hermes-sandbox" || return 1
  printf 'prev:broker\n' > "$t/model_broker.py" || return 1
  chmod 644 "$t/model_broker.py" || return 1
  chmod 755 "$t" || return 1
  DEPLOY_TARGET="$t"
  TARGET_OWNER="$(id -un):$(id -gn)"
  TARGET_MODE="$(mode_of "$t")"
  for name in "${DEP_ORDER[@]}"; do
    DEP_SHA[$name]="$(sha "$t/$name")"
    DEP_OWNER[$name]="$TARGET_OWNER"
    DEP_MODE[$name]="$(mode_of "$t/$name")"
  done
  for name in "${!PAYLOAD_PREDECESSOR[@]}"; do
    PAYLOAD_PREDECESSOR[$name]="$(sha "$t/$name")"
  done
  for name in "${PAYLOAD_ORDER[@]}"; do
    PAYLOAD_OWNER[$name]="$TARGET_OWNER"
  done
  return 0
}

st_package() {
  package_integrity && ok deploy_package_integrity || no deploy_package_integrity
}

st_syntax() {
  if bash -n "$PKG/bin/run_smoke.sh" && bash -n "$PKG/bin/bootstrap.sh" \
     && bash -n "$PINS"; then
    ok deploy_syntax
  else
    no deploy_syntax
  fi
  if python3 - "$PKG" <<'PY'
import sys
base = sys.argv[1]
for name in ("model_broker.py", "tool_event_client.py", "tool_observer_config.py"):
    compile(open(base + "/payload/" + name, encoding="utf-8").read(), name, "exec")
PY
  then ok deploy_python_syntax; else no deploy_python_syntax; fi
}

st_pins() {
  local bad=0 name
  [ "${#PAYLOAD_ORDER[@]}" -eq 4 ] || bad=1
  [ "${#NEW_PAYLOADS[@]}" -eq 2 ] || bad=1
  [ "${#DEP_ORDER[@]}" -eq 12 ] || bad=1
  [ "$CANDIDATE_COMMIT" = "926c34fbecf1157c2ae88e57e85ef67f6f82de33" ] || bad=1
  [ "$CHECK_SOURCE_COMMIT" = "4232cb114f74dbbbf15046cce6e62ec95604bbd7" ] || bad=1
  [ "$R10_ROOT_ANCHOR" = \
    "e458957cd15cab763191b031cc2598af5a4c7c2136fe951c629d40e414081f65" ] || bad=1
  [ "${DEP_SHA[guard/contract_guard.py]}" = \
    "19f6be638c37b28d401820b7a4562f852a459188cbfa793f757668fe9b330455" ] || bad=1
  for name in "${PAYLOAD_ORDER[@]}"; do
    [ -n "${PAYLOAD_SHA[$name]:-}" ] && [ -n "${PAYLOAD_MODE[$name]:-}" ] \
      && [ -n "${PAYLOAD_OWNER[$name]:-}" ] || bad=1
  done
  for name in "${NEW_PAYLOADS[@]}"; do
    [ -z "${PAYLOAD_PREDECESSOR[$name]:-}" ] || bad=1
  done
  [ "$bad" -eq 0 ] && ok deploy_pins || no deploy_pins
}

st_active_run() {
  local tmp; tmp="$(mktemp -d /var/tmp/aegl-deploy-ar.XXXXXX)" \
    || { no deploy_active_run; return; }
  local flag=0
  if (
    . "$PINS"
    bad=0 rc=0 oldpath=""
    mkdir -p "$tmp/stub"
    cat > "$tmp/stub/pgrep" <<'SH'
#!/bin/sh
case "${FAKE_PGREP_MODE:-none}" in
  hit) printf '123 aegl-hermes-sandbox --task X\n'; exit 0 ;;
  error) exit 3 ;;
  *) exit 1 ;;
esac
SH
    chmod 0755 "$tmp/stub/pgrep"
    oldpath="$PATH"; PATH="$tmp/stub:/usr/bin:/bin"
    export FAKE_PGREP_MODE=none
    rc=0; active_run_check "$tmp/absent" || rc=$?; [ "$rc" -eq 0 ] || bad=1
    mkdir -p "$tmp/empty"
    rc=0; active_run_check "$tmp/empty" || rc=$?; [ "$rc" -eq 0 ] || bad=1
    mkdir -p "$tmp/busy/task1"; : > "$tmp/busy/task1/marker"
    rc=0; active_run_check "$tmp/busy" || rc=$?; [ "$rc" -eq 1 ] || bad=1
    ln -s "$tmp/empty" "$tmp/link"
    rc=0; active_run_check "$tmp/link" || rc=$?; [ "$rc" -eq 2 ] || bad=1
    : > "$tmp/notdir"
    rc=0; active_run_check "$tmp/notdir" || rc=$?; [ "$rc" -eq 2 ] || bad=1
    mkdir -p "$tmp/emptyrun"
    export FAKE_PGREP_MODE=hit
    rc=0; active_run_check "$tmp/emptyrun" || rc=$?; [ "$rc" -eq 1 ] || bad=1
    export FAKE_PGREP_MODE=error
    rc=0; active_run_check "$tmp/emptyrun" || rc=$?; [ "$rc" -eq 2 ] || bad=1
    export FAKE_PGREP_MODE=none
    rc=0; active_run_check "$tmp/emptyrun" || rc=$?; [ "$rc" -eq 0 ] || bad=1
    PATH="$oldpath"
    exit "$bad"
  ); then flag=1; fi
  [ "$flag" -eq 1 ] && ok deploy_active_run || no deploy_active_run
  rm -rf -- "$tmp"
}

st_install_logic() {
  local tmp; tmp="$(mktemp -d /var/tmp/aegl-deploy-sim.XXXXXX)" \
    || { no deploy_install_logic; return; }
  local flag=0
  if (
    . "$PINS"
    bad=0 rc=0 t="" name="" oldpath=""
    export PATH="/usr/bin:/bin:$PATH"

    # success: preflight, register, install order, verify, cleanup
    t="$tmp/ok"; sim_prepare "$t" || exit 1
    preflight "$t" || bad=1
    register_temps "$t" || bad=1
    [ "${#TEMP_PATHS[@]}" -eq 4 ] || bad=1
    for p in "${TEMP_PATHS[@]}"; do is_absent "$p" || bad=1; done
    install_all "$t" || bad=1
    [ "${INSTALLED_ORDER[*]}" = "tool_event_client.py tool_observer_config.py model_broker.py aegl-hermes-sandbox" ] || bad=1
    post_verify "$t" || bad=1
    cleanup_temps || bad=1
    if find "$t" -maxdepth 1 -name '.aegl-deploy.*' -print -quit | grep -q .; then bad=1; fi
    for name in "${PAYLOAD_ORDER[@]}"; do
      [ "$(sha "$t/$name")" = "${PAYLOAD_SHA[$name]}" ] || bad=1
      [ "$(owner_of "$t/$name")" = "${PAYLOAD_OWNER[$name]}" ] || bad=1
      [ "$(mode_of "$t/$name")" = "${PAYLOAD_MODE[$name]}" ] || bad=1
    done

    # new target already present
    t="$tmp/new-exists"; sim_prepare "$t" || exit 1
    printf 'x\n' > "$t/tool_observer_config.py"
    rc=0; preflight "$t" || rc=$?
    [ "$rc" -ne 0 ] && [ "$FAIL_STAGE" = new_target_exists ] || bad=1

    # predecessor hash
    t="$tmp/pred"; sim_prepare "$t" || exit 1
    printf 'changed\n' > "$t/aegl-hermes-sandbox"
    rc=0; preflight "$t" || rc=$?
    [ "$rc" -ne 0 ] && [ "$FAIL_STAGE" = predecessor_hash ] || bad=1

    # dependency hash (guard specifically)
    t="$tmp/dep"; sim_prepare "$t" || exit 1
    rm -f -- "$t/guard/contract_guard.py"
    printf 'changed\n' > "$t/guard/contract_guard.py"
    chmod 0444 "$t/guard/contract_guard.py"
    rc=0; preflight "$t" || rc=$?
    [ "$rc" -ne 0 ] && [ "$FAIL_STAGE" = dependency_hash ] || bad=1

    # dependency mode
    t="$tmp/depmode"; sim_prepare "$t" || exit 1
    chmod 0644 "$t/guard/contract_guard.py"
    rc=0; preflight "$t" || rc=$?
    [ "$rc" -ne 0 ] && [ "$FAIL_STAGE" = dependency_mode ] || bad=1

    # missing dependency
    t="$tmp/depmissing"; sim_prepare "$t" || exit 1
    rm -f -- "$t/diag_events.py"
    rc=0; preflight "$t" || rc=$?
    [ "$rc" -ne 0 ] && [ "$FAIL_STAGE" = dependency_state ] || bad=1

    # predecessor symlink
    t="$tmp/predlink"; sim_prepare "$t" || exit 1
    rm -f -- "$t/model_broker.py"
    ln -s "$t/aegl-hermes-sandbox" "$t/model_broker.py"
    rc=0; preflight "$t" || rc=$?
    [ "$rc" -ne 0 ] && [ "$FAIL_STAGE" = predecessor_state ] || bad=1

    # target directory is a symlink
    t="$tmp/targetlink"; sim_prepare "$t" || exit 1
    ln -s "$t" "$tmp/targetlink.link"
    rc=0; preflight "$tmp/targetlink.link" || rc=$?
    [ "$rc" -ne 0 ] && [ "$FAIL_STAGE" = target_state ] || bad=1

    # stale temp conflict
    t="$tmp/tempconflict"; sim_prepare "$t" || exit 1
    : > "$t/.aegl-deploy.stale"
    rc=0; register_temps "$t" || rc=$?
    [ "$rc" -ne 0 ] && [ "$FAIL_STAGE" = temp_conflict ] || bad=1

    # mid-install failure: second rename fails; later files are not installed
    t="$tmp/mid"; sim_prepare "$t" || exit 1
    preflight "$t" || exit 1
    register_temps "$t" || exit 1
    mkdir -p "$tmp/stub"
    cat > "$tmp/stub/mv" <<'SH'
#!/bin/sh
case "$*" in
  *"/tool_observer_config.py") exit 9 ;;
esac
exec /bin/mv "$@"
SH
    chmod 0755 "$tmp/stub/mv"
    oldpath="$PATH"; PATH="$tmp/stub:/usr/bin:/bin"
    rc=0; install_all "$t" || rc=$?
    PATH="$oldpath"
    [ "$rc" -eq 9 ] || bad=1
    [ "$FAIL_STAGE" = "rename_tool_observer_config.py" ] || bad=1
    [ "${INSTALLED_ORDER[*]}" = "tool_event_client.py" ] || bad=1
    [ "$(sha "$t/tool_event_client.py")" = "${PAYLOAD_SHA[tool_event_client.py]}" ] || bad=1
    is_absent "$t/tool_observer_config.py" || bad=1
    if ! find "$t" -maxdepth 1 -name '*.tool_observer_config.py' -print -quit | grep -q .; then bad=1; fi
    [ "$(sha "$t/model_broker.py")" = "${PAYLOAD_PREDECESSOR[model_broker.py]}" ] || bad=1
    [ "$(sha "$t/aegl-hermes-sandbox")" = "${PAYLOAD_PREDECESSOR[aegl-hermes-sandbox]}" ] || bad=1

    exit "$bad"
  ); then flag=1; fi
  [ "$flag" -eq 1 ] && ok deploy_install_logic || no deploy_install_logic
  rm -rf -- "$tmp"
}

self_test() {
  say "DEPLOY_SELF_TEST begin pkg=$PKG"
  st_package
  st_syntax
  st_pins
  st_active_run
  st_install_logic
  notrun root_real_install
  notrun root_real_active_run_scan
  notrun r10_root_check_rerun
  notrun production_23_suite
  say "DEPLOY_SELF_TEST pass=$PASS fail=$FAIL"
  [ "$FAIL" -eq 0 ]
}

case "$MODE" in
  self-test) self_test ;;
  deploy) deploy_main ;;
esac
