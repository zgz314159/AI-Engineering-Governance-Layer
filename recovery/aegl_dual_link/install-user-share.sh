#!/usr/bin/env bash
# Sync in-repo dual-link sources into ~/.local/share/aegl-dual-link.
# Does not overwrite an existing project-control-map.json.
set -euo pipefail
SRC=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
DEST=${AEGL_DUAL_LINK_HOME:-$HOME/.local/share/aegl-dual-link}
mkdir -p "$DEST"

# Executables / helpers (IME-safe CDP + Command Code advise round-trip included)
for f in dual-link-operator.sh aegl-calendar-prepare after-sudo-continue.sh \
         install-nopasswd-prepare.sh ensure-cdp-control.sh cdp_chat.py advise_post.py; do
  [[ -f $SRC/$f ]] || { echo "MISSING $SRC/$f" >&2; exit 1; }
  install -m 0755 "$SRC/$f" "$DEST/$f"
done

# Libraries / config fragments
for f in project_control.py sudoers-aegl-calendar-prepare; do
  install -m 0644 "$SRC/$f" "$DEST/$f"
done
# project_control was installed 0644 above; advise/cdp stay 0755

if [[ ! -f $DEST/project-control-map.json ]]; then
  cp "$SRC/project-control-map.example.json" "$DEST/project-control-map.json"
  echo "CREATED $DEST/project-control-map.json from example"
else
  echo "KEEP existing $DEST/project-control-map.json"
fi
cp "$SRC/project-control-map.example.json" "$DEST/project-control-map.example.json"
# Keep installer itself in DEST for re-run from share
install -m 0755 "$SRC/install-user-share.sh" "$DEST/install-user-share.sh" 2>/dev/null || true

echo "INSTALLED dual-link -> $DEST"
echo "SOURCE $SRC"
echo "helpers: ensure-cdp-control.sh cdp_chat.py advise_post.py"
