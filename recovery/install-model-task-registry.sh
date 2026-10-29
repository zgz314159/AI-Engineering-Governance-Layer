#!/usr/bin/env bash
# Install/upgrade only the frozen registry CLI/module. No registry, model or service calls.
CLI_REL="bin/aegl-model-task"
MOD_REL="recovery/model_task_registry.py"
CLI_SHA="edb38c2155f617417c8f225128144fba94c822db317a799613fa5e9203669b6e"
MOD_SHA="baa7133e990a9009256068ac75b772a79d426a45678cd010b8301cdb6dc41491"
MOD_SHA_OLD="0b9376ef1be8cc1c26a6916c892e619d169b41dc6090818637a1b4fb35d923de"
TARGET="/usr/local/lib/aegl-model-task"
PARENT_DIR="/usr/local/lib"

fail() { printf 'INSTALL_FAILED reason=%s %s\n' "$1" "${2:-}" >&2; exit 1; }
sha() { sha256sum "$1" | awk '{print $1}'; }
install_target_state() {
  local f="$1/$MOD_REL" current
  if [[ -L "$1" || -L "$f" ]]; then printf 'UNKNOWN\n'; return; fi
  if [[ ! -e "$1" ]]; then printf 'ABSENT\n'; return; fi
  if [[ ! -f "$f" ]]; then printf 'UNKNOWN\n'; return; fi
  current=$(sha "$f") || return
  case "$current" in
    "$MOD_SHA") printf 'ALREADY_NEW\n' ;;
    "$MOD_SHA_OLD") printf 'UPGRADABLE\n' ;;
    *) printf 'UNKNOWN\n' ;;
  esac
}
trusted() { # exact owner/group/mode, no symlinks
  [[ ! -L "$1" ]] || fail symlink "$1"
  [[ $(stat -c '%u:%g %a' "$1") == "0:0 $2" ]] || fail owner_mode "$1"
}
verify_installed() {
  local rel
  for rel in '' /bin /recovery; do trusted "$TARGET$rel" 755; done
  trusted "$TARGET/$CLI_REL" 755
  trusted "$TARGET/$MOD_REL" 644
  [[ $(sha "$TARGET/$CLI_REL") == "$CLI_SHA" ]] || fail installed_cli_hash
  [[ $(sha "$TARGET/$MOD_REL") == "$MOD_SHA" ]] || fail installed_module_hash
  PYTHONDONTWRITEBYTECODE=1 "$TARGET/$CLI_REL" --help >/dev/null || fail entrypoint_unusable
  printf 'INSTALL_LOADED_MODULE=%s\n' "$TARGET/$MOD_REL"
}
main() {
  set -euo pipefail
  export PYTHONDONTWRITEBYTECODE=1
  [[ $(id -u) == 0 ]] || fail need_root
  local upgrade=0 payload='' state rel stage=''
  while (($#)); do
    case "$1" in
      --upgrade) upgrade=1; shift ;;
      --payload-dir) payload=${2:?}; shift 2 ;;
      *) fail usage "$1" ;;
    esac
  done
  [[ -n $payload && ! -L $payload ]] || fail payload_path
  [[ $(realpath -e "$payload") == "$payload" ]] || fail payload_not_canonical
  trusted "$payload" 700
  for rel in bin recovery; do trusted "$payload/$rel" 700; done
  for rel in "$CLI_REL" "$MOD_REL" recovery/gt1-install-manifest.txt; do
    [[ -f "$payload/$rel" && ! -L "$payload/$rel" ]] || fail payload_file "$rel"
    [[ $(stat -c '%u:%g' "$payload/$rel") == 0:0 ]] || fail payload_owner "$rel"
    (( (8#$(stat -c '%a' "$payload/$rel") & 8#022) == 0 )) || fail payload_writable "$rel"
  done
  [[ $(sha "$payload/$CLI_REL") == "$CLI_SHA" ]] || fail cli_hash
  [[ $(sha "$payload/$MOD_REL") == "$MOD_SHA" ]] || fail module_hash
  trusted "$PARENT_DIR" 755
  state=$(install_target_state "$TARGET")
  case "$state" in
    ALREADY_NEW)
      verify_installed
      echo 'INSTALL_MODE=already_new'
      echo 'INSTALL=OK'
      return ;;
    UPGRADABLE)
      ((upgrade == 1)) || fail target_exists_use_upgrade
      for rel in '' /bin /recovery; do trusted "$TARGET$rel" 755; done
      trusted "$TARGET/$CLI_REL" 755
      trusted "$TARGET/$MOD_REL" 644
      [[ $(sha "$TARGET/$CLI_REL") == "$CLI_SHA" ]] || fail old_cli_hash ;;
    ABSENT) ((upgrade == 0)) || fail upgrade_target_missing ;;
    *) fail unknown_installed_version ;;
  esac
  stage=$(mktemp -d "$PARENT_DIR/.aegl-model-task.install.XXXXXX")
  printf 'INSTALL_STAGING=%s\n' "$stage"
  # Retain a failed stage. On success remove only the two verified, known members.
  install -d -o root -g root -m 0755 "$stage/bin" "$stage/recovery"
  install -o root -g root -m 0755 "$payload/$CLI_REL" "$stage/$CLI_REL"
  install -o root -g root -m 0644 "$payload/$MOD_REL" "$stage/$MOD_REL"
  [[ $(sha "$stage/$CLI_REL") == "$CLI_SHA" ]] || fail staged_cli_hash
  [[ $(sha "$stage/$MOD_REL") == "$MOD_SHA" ]] || fail staged_module_hash
  if [[ $state == ABSENT ]]; then
    [[ ! -e $TARGET && ! -L $TARGET ]] || fail target_appeared
    chmod 0755 "$stage"
    mv -T "$stage" "$TARGET"
  else
    # The CLI bytes do not change. Replace just the module, after rechecking the old
    # version immediately before rename; one file boundary, no mixed CLI/module API.
    [[ $(sha "$TARGET/$MOD_REL") == "$MOD_SHA_OLD" ]] || fail target_changed_during_upgrade
    [[ $(sha "$TARGET/$CLI_REL") == "$CLI_SHA" ]] || fail cli_changed_during_upgrade
    mv -T "$stage/$MOD_REL" "$TARGET/$MOD_REL"
    rm -- "$stage/$CLI_REL"
    rmdir -- "$stage/bin" "$stage/recovery" "$stage"
  fi
  verify_installed
  printf 'INSTALL_MODE=%s\n' "$state"
  echo 'INSTALL=OK'
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
