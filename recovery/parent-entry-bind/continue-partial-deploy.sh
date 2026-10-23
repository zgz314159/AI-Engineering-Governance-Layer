#!/usr/bin/env bash
# continue-partial-deploy.sh — resume after mounts+policy OK but checker refused,
# and model-broker not yet installed. Does NOT reinstall mount units.
#
# Preconditions (already done on host):
#   main @ tip parent or later; r59 APPLIED; five binds live; policy written.
#
# Order (checker BEFORE promote — running broker gates on installed checker):
#   1) replace only /usr/local/lib/aegl-entry-bind/require-entry-binds.sh from TIP
#   2) run checker once against live mounts
#   3) caller promotes THIS tip with a NEW task-id (not r59) + formal sync
#   4) install-model-broker from TIP (no --self-test)
#
# Usage (from root-only extracted copy after hash verify):
#   bash continue-partial-deploy.sh --tip <40-hex> --aegl <AEGL> --phase checker
#   bash continue-partial-deploy.sh --tip <40-hex> --aegl <AEGL> --phase model
set -euo pipefail

TIP=""; AEGL=""; PHASE=""
LIBEB=/usr/local/lib/aegl-entry-bind
CHECKER=$LIBEB/require-entry-binds.sh

while [ $# -gt 0 ]; do
  case "$1" in
    --tip) TIP="${2:-}"; shift 2 ;;
    --aegl) AEGL="${2:-}"; shift 2 ;;
    --phase) PHASE="${2:-}"; shift 2 ;;
    *) printf 'CONTINUE_ERROR: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ "$(id -u)" = 0 ] || { printf 'CONTINUE_ERROR: must run as root\n' >&2; exit 1; }
[ -n "$TIP" ] && [ "${#TIP}" -eq 40 ] || { printf 'CONTINUE_ERROR: --tip <40-hex>\n' >&2; exit 1; }
[ -n "$AEGL" ] && [ -d "$AEGL/.git" ] || { printf 'CONTINUE_ERROR: --aegl\n' >&2; exit 1; }
case "$PHASE" in checker|model) ;; *) printf 'CONTINUE_ERROR: --phase checker|model\n' >&2; exit 1 ;; esac

say(){ printf '%s\n' "$*"; }
die(){ printf 'CONTINUE_ERROR: %s\n' "$*" >&2; exit 1; }
git_aegl(){ git -C "$AEGL" -c "safe.directory=$AEGL" "$@"; }

export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=safe.directory
export GIT_CONFIG_VALUE_0="$AEGL"

git_aegl cat-file -e "$TIP^{commit}" || die "tip not in AEGL object store: $TIP"

case "$PHASE" in
  checker)
    say "== phase=checker: install require-entry-binds.sh only =="
    [ -d "$LIBEB" ] || die "missing $LIBEB (entry-bind pack not installed)"
    [ -f /etc/aegl/entry-bind/policy ] || die "policy missing — not a partial-deploy resume"
    STAGE="$(mktemp)"
    git_aegl show "$TIP:recovery/parent-entry-bind/require-entry-binds.sh" > "$STAGE"
    WANT="$(git_aegl show "$TIP:recovery/parent-entry-bind/require-entry-binds.sh" | sha256sum | awk '{print $1}')"
    GOT="$(sha256sum "$STAGE" | awk '{print $1}')"
    [ "$WANT" = "$GOT" ] || die "checker extract hash mismatch want=$WANT got=$GOT"
    install -o root -g root -m 0755 "$STAGE" "$CHECKER"
    rm -f "$STAGE"
    GOT2="$(sha256sum "$CHECKER" | awk '{print $1}')"
    [ "$WANT" = "$GOT2" ] || die "installed checker hash mismatch"
    say "CHECKER_INSTALLED path=$CHECKER sha256=$GOT2"
    say "== run live require-entry-binds once =="
    bash "$CHECKER" || die "require-entry-binds failed after checker replace"
    say "CHECKER_LIVE_OK"
    say "NEXT: promote tip $TIP with NEW task-id (not parent-entry-bind-r59), sync formal, then --phase model"
    ;;
  model)
    say "== phase=model: install-model-broker (no --self-test) =="
    bash "$CHECKER" || die "checker must still pass before model install"
    RDIR="$(mktemp -d /var/tmp/aegl-model-install-XXXXXX)"
    chmod 0700 "$RDIR"
    git_aegl show "$TIP:recovery/install-model-broker.sh" > "$RDIR/install-model-broker.sh"
    chmod 0755 "$RDIR/install-model-broker.sh"
    WANT="$(git_aegl show "$TIP:recovery/install-model-broker.sh" | sha256sum | awk '{print $1}')"
    GOT="$(sha256sum "$RDIR/install-model-broker.sh" | awk '{print $1}')"
    [ "$WANT" = "$GOT" ] || die "install-model-broker hash mismatch"
    bash "$RDIR/install-model-broker.sh" --repo "$AEGL" --commit "$TIP"
    rm -f "$RDIR/install-model-broker.sh"
    rmdir "$RDIR" 2>/dev/null || true
    say "MODEL_BROKER_INSTALL_OK commit=$TIP"
    ;;
esac
