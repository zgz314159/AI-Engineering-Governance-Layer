#!/usr/bin/env bash
# Targeted, manifest-pinned deployment of configurable provider selection.
# No Git access, key reads/copies, provider selection, model calls, or backups.
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB=/usr/local/lib/aegl-model
CLI=/usr/local/bin/aegl-model-config
ANCHOR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --package-anchor) ANCHOR="${2:-}"; shift 2 ;;
    *) echo 'INSTALL_ERROR=unknown_argument' >&2; exit 2 ;;
  esac
done
[ "$(id -u)" = 0 ] || { echo 'INSTALL_ERROR=root_required' >&2; exit 1; }
[[ "$ANCHOR" =~ ^[a-f0-9]{64}$ ]] || { echo 'INSTALL_ERROR=package_anchor_required' >&2; exit 1; }
[ "$(sha256sum "$SELF_DIR/MANIFEST.sha256" | awk '{print $1}')" = "$ANCHOR" ] || { echo 'INSTALL_ERROR=anchor_mismatch' >&2; exit 1; }
(cd "$SELF_DIR" && sha256sum -c MANIFEST.sha256 >/dev/null) || exit 1

# Bind the currently deployed 008 launcher. Do not overwrite a later/foreign build.
check(){
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(sha256sum "$1" | awk '{print $1}')" = "$2" ] \
    || { echo "INSTALL_ERROR=baseline_changed path=$1" >&2; exit 1; }
}
check "$LIB/aegl-hermes-sandbox" 36949c31f6437ad45afc066f51cce5b0477c0c52ba3ccefc624be33cbdf6a699
check "$LIB/model_broker.py" 29ecedf420cd455e556780a3ddcfd98966d8aab7bc154e46a759a015b096ab32
cmp -s "$SELF_DIR/payload/aegl-model-broker" "$LIB/aegl-model-broker" \
  || { echo 'INSTALL_ERROR=broker_wrapper_changed' >&2; exit 1; }
[ -f /etc/aegl/model/config ] || { echo 'INSTALL_ERROR=runtime_config_missing' >&2; exit 1; }
if [ -e "$CLI" ] || [ -L "$CLI" ]; then
  [ -L "$CLI" ] && [ "$(readlink "$CLI")" = "$LIB/aegl-model-config" ] \
    || { echo 'INSTALL_ERROR=foreign_cli_path' >&2; exit 1; }
fi
# Validate the literal legacy runtime config before installing the new launcher.
python3 - "$SELF_DIR/payload/model_config.py" <<'PY'
import importlib.util,sys
from pathlib import Path
spec=importlib.util.spec_from_file_location('model_config',sys.argv[1])
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
module.read_config(Path('/etc/aegl/model/config'))
PY

install -o root -g root -m 0644 "$SELF_DIR/payload/model_config.py" "$LIB/model_config.py"
install -o root -g root -m 0755 "$SELF_DIR/payload/aegl-model-config" "$LIB/aegl-model-config"
install -o root -g root -m 0755 "$SELF_DIR/payload/aegl-hermes-sandbox" "$LIB/aegl-hermes-sandbox"
if [ ! -L "$CLI" ]; then ln -s "$LIB/aegl-model-config" "$CLI"; fi
for file in model_config.py aegl-model-config aegl-hermes-sandbox; do
  cmp -s "$SELF_DIR/payload/$file" "$LIB/$file" || { echo 'INSTALL_ERROR=installed_bytes_mismatch' >&2; exit 1; }
done
echo 'PROVIDER_CONFIG_INSTALL=OK'
if "$LIB/aegl-model-config" validate; then
  echo 'ACTIVE_MODEL_ROUTE=CONFIGURED (not a model-call acceptance)'
else
  echo 'ACTIVE_MODEL_ROUTE=CONFIGURE_REQUIRED (save/use a provider before tasks)'
fi
echo 'MODEL_CALLS=0 KEY_CHANGES=0'
