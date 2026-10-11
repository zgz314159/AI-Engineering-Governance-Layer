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
REPO=""; COMMIT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --commit) COMMIT="${2:-}"; shift 2 ;;
    *) printf 'INSTALL_ERROR: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
done
LIBDIR="/usr/local/lib/aegl-model"
CREDDIR="/etc/aegl/model"
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

say "  program: $LIBDIR (aegl-model-broker, aegl-hermes-sandbox, model_broker.py, loopback_shim.py)"
say "  credential dir (root-only, place the provider credential here): $CREDDIR"
say ""
say "NOT done: it does not create the model credential or write it anywhere (the sandbox reads the"
say "existing COMMANDCODE_API_KEY from its original location), does not run 'switch', change project"
say "permissions, merge any project, or write /etc/aegl/broker-verified. Trial command:"
say "  sudo $LIBDIR/aegl-hermes-sandbox --task <id> -- hermes -p android-stack chat --oneshot --query-file <prompt>"
printf 'INSTALL_RESULT=OK commit=%s\n' "$COMMIT"
