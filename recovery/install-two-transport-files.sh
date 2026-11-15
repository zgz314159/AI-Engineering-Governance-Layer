#!/usr/bin/env bash
# Install ONLY the reviewed model_broker.py and loopback_shim.py transport fixes.
# Root only. No launcher start, no pin/history edit, no backup, no rollback, no retry.
# Existing pattern: same-directory root-owned temp + atomic mv, with fixed hashes and
# re-verification immediately before and after each replacement.
set -uo pipefail

DEST="/usr/local/lib/aegl-model"
SRC="/var/tmp/IAP-CONTROL-DEV/aegl/recovery"
MODEL="model_broker.py"
SHIM="loopback_shim.py"
RUN_ROOT="/run/aegl-model"

OLD_MODEL="7aa88b1831ca18fdbe9b14273321a90b352bb6026299b9bb9c26d4ca9b8ee59a"
NEW_MODEL="b9ff6a51c70f47a3a90f22f5303a321d3de2521ed85db31680a46c6573a57fb1"
OLD_SHIM="75cf4ad616d4d40a5529e4f263267c08b521ef26bf9cc4a556814e44a4031d5c"
NEW_SHIM="40e71b3da01cd6344b7426aa4474f37ebd41f9c94cf9ecc98f7958372ef689cc"

# Necessary dependencies: the wrapper, broker diagnostics, and guard capture.
DEP_NAMES=(aegl-model-broker diag_events.py guard_capture.py)
DEP_SHAS=(
  e7ca9db0fbd029cb3fb72b163e792fe9c62ca6b85c571569cf2ad9319917fba9
  0f79ca1f4eaae497aaef7b93ae2ee5587e23be2c3aec3cd47a0524dda47f4f2e
  4422f725fc2fb88ecff4de6baba81a519e4f450be5ad644948b29745d877be1a
)
DEP_MODES=(755 644 644)

STAGE="PREFLIGHT"
COMPLETED=()
TMP_MODEL=""
TMP_SHIM=""

say() { printf '%s\n' "$*"; }
fail() {
  local stage="${1:-UNKNOWN}" rc="${2:-1}"
  [ "$rc" -ne 0 ] || rc=1
  printf 'INSTALL_FAIL stage=%s rc=%s completed=%s temp_model=%s temp_shim=%s\n' \
    "$stage" "$rc" "${COMPLETED[*]:-none}" "${TMP_MODEL:-none}" "${TMP_SHIM:-none}" >&2
  exit "$rc"
}
h() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
owner_mode() { stat -c '%U:%G %a' "$1" 2>/dev/null; }

is_regular() { [ -f "$1" ] && [ ! -L "$1" ]; }

verify_target_old() { # <path> <old-hash> <label>
  local path="$1" old="$2" label="$3"
  is_regular "$path" || fail "target_state_${label}" 1
  [ "$(owner_mode "$path")" = "root:root 644" ] || fail "target_mode_${label}" 1
  [ "$(h "$path")" = "$old" ] || fail "target_predecessor_${label}" 1
}

verify_temp_new() { # <path> <new-hash> <label>
  local path="$1" new="$2" label="$3"
  is_regular "$path" || fail "temp_state_${label}" 1
  [ "$(owner_mode "$path")" = "root:root 644" ] || fail "temp_mode_${label}" 1
  [ "$(h "$path")" = "$new" ] || fail "temp_hash_${label}" 1
}

verify_target_new() { # <path> <new-hash> <label>
  local path="$1" new="$2" label="$3"
  is_regular "$path" || fail "installed_state_${label}" 1
  [ "$(owner_mode "$path")" = "root:root 644" ] || fail "installed_mode_${label}" 1
  [ "$(h "$path")" = "$new" ] || fail "installed_hash_${label}" 1
}

verify_deps() {
  local i path
  for i in "${!DEP_NAMES[@]}"; do
    path="$DEST/${DEP_NAMES[$i]}"
    is_regular "$path" || fail "dependency_state_${DEP_NAMES[$i]}" 1
    [ "$(owner_mode "$path")" = "root:root ${DEP_MODES[$i]}" ] \
      || fail "dependency_mode_${DEP_NAMES[$i]}" 1
    [ "$(h "$path")" = "${DEP_SHAS[$i]}" ] \
      || fail "dependency_hash_${DEP_NAMES[$i]}" 1
  done
}

check_active() {
  local out rc
  out="$(ps -eo pid=,args=)" || fail active_probe_ps $?
  printf '%s\n' "$out" | awk -v self="$$" '
    $1 == self { next }
    {
      line = $0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", line)
      if (line ~ /(^|\/)(run_registered_task|aegl-hermes-sandbox|aegl-model-broker|model_broker[.]py)([[:space:]]|$)/) {
        found = 1
      }
    }
    END { exit(found ? 0 : 1) }'
  rc=$?
  case "$rc" in
    0) fail active_task 1 ;;
    1) ;;
    *) fail active_probe_awk "$rc" ;;
  esac
}

check_run_root() {
  local entries
  if [ -L "$RUN_ROOT" ]; then fail run_root_link 1; fi
  if [ -e "$RUN_ROOT" ]; then
    [ -d "$RUN_ROOT" ] || fail run_root_type 1
    entries="$(ls -A "$RUN_ROOT")" || fail run_root_read $?
    [ -z "$entries" ] || fail run_root_not_empty 1
  fi
}

snapshot_others() {
  local f rel
  for f in "$DEST"/* "$DEST"/guard/*; do
    [ -f "$f" ] || continue
    rel="${f#"$DEST"/}"
    [ "$rel" = "$MODEL" ] && continue
    [ "$rel" = "$SHIM" ] && continue
    sha256sum "$f" || return $?
  done
}

[ "$(id -u)" -eq 0 ] || fail not_root 1
[ -d "$DEST" ] || fail dest_missing 1
[ ! -L "$DEST" ] || fail dest_link 1
[ -d "$SRC" ] || fail source_dir 1

check_active
check_run_root

verify_target_old "$DEST/$MODEL" "$OLD_MODEL" model
verify_target_old "$DEST/$SHIM" "$OLD_SHIM" shim

stale="$(find "$DEST" -maxdepth 1 \( -name ".model_broker.py.install.*" -o -name ".loopback_shim.py.install.*" \) -print)" \
  || fail stale_probe $?
[ -z "$stale" ] || fail stale_temp 1

is_regular "$SRC/$MODEL" || fail candidate_source_state_model 1
is_regular "$SRC/$SHIM" || fail candidate_source_state_shim 1
[ "$(h "$SRC/$MODEL")" = "$NEW_MODEL" ] || fail candidate_hash_model 1
[ "$(h "$SRC/$SHIM")" = "$NEW_SHIM" ] || fail candidate_hash_shim 1

verify_deps
SNAP_BEFORE="$(snapshot_others)" || fail snapshot_before $?
STAGE="PREFLIGHT_OK"

TMP_MODEL="$DEST/.${MODEL}.install.$$"
TMP_SHIM="$DEST/.${SHIM}.install.$$"
for p in "$TMP_MODEL" "$TMP_SHIM"; do
  [ ! -e "$p" ] && [ ! -L "$p" ] || fail temp_path_present 1
done

install -o root -g root -m 0644 -- "$SRC/$MODEL" "$TMP_MODEL" || fail stage_model $?
install -o root -g root -m 0644 -- "$SRC/$SHIM" "$TMP_SHIM" || fail stage_shim $?
verify_temp_new "$TMP_MODEL" "$NEW_MODEL" model
verify_temp_new "$TMP_SHIM" "$NEW_SHIM" shim
COMPLETED+=(STAGED)
STAGE="STAGED"

# Re-verify immediately before the first irreversible replacement.
verify_target_old "$DEST/$MODEL" "$OLD_MODEL" model
verify_target_old "$DEST/$SHIM" "$OLD_SHIM" shim
verify_temp_new "$TMP_MODEL" "$NEW_MODEL" model
verify_temp_new "$TMP_SHIM" "$NEW_SHIM" shim
verify_deps
[ "$SNAP_BEFORE" = "$(snapshot_others)" ] || fail side_effect_before_replace 1
STAGE="REPLACE_MODEL"
mv -f -- "$TMP_MODEL" "$DEST/$MODEL" || fail replace_model $?
COMPLETED+=(REPLACED_MODEL)
verify_target_new "$DEST/$MODEL" "$NEW_MODEL" model
TMP_MODEL=""

STAGE="REPLACE_SHIM"
verify_target_old "$DEST/$SHIM" "$OLD_SHIM" shim
verify_temp_new "$TMP_SHIM" "$NEW_SHIM" shim
mv -f -- "$TMP_SHIM" "$DEST/$SHIM" || fail replace_shim $?
COMPLETED+=(REPLACED_SHIM)
verify_target_new "$DEST/$SHIM" "$NEW_SHIM" shim
TMP_SHIM=""

STAGE="POST_VERIFY"
verify_target_new "$DEST/$MODEL" "$NEW_MODEL" model
verify_target_new "$DEST/$SHIM" "$NEW_SHIM" shim
verify_deps
[ "$SNAP_BEFORE" = "$(snapshot_others)" ] || fail side_effect_after_replace 1
for p in "$DEST/.${MODEL}.install."* "$DEST/.${SHIM}.install."*; do
  [ ! -e "$p" ] && [ ! -L "$p" ] || fail temp_leftover 1
done
COMPLETED+=(VERIFIED)
STAGE="DONE"
say "INSTALL_OK model=$NEW_MODEL shim=$NEW_SHIM deps=UNCHANGED"
