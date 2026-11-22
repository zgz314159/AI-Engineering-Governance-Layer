#!/usr/bin/env bash
# Sync in-repo dual-link sources into ~/.local/share/aegl-dual-link.
# Does not overwrite an existing project-control-map.json.
set -euo pipefail
SRC=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
DEST=${AEGL_DUAL_LINK_HOME:-$HOME/.local/share/aegl-dual-link}
mkdir -p "$DEST"
for f in dual-link-operator.sh project_control.py aegl-calendar-prepare \
         after-sudo-continue.sh install-nopasswd-prepare.sh sudoers-aegl-calendar-prepare; do
  install -m 0755 "$SRC/$f" "$DEST/$f"
done
# project_control.py should be 0644
chmod 0644 "$DEST/project_control.py" "$DEST/sudoers-aegl-calendar-prepare"
if [[ ! -f $DEST/project-control-map.json ]]; then
  cp "$SRC/project-control-map.example.json" "$DEST/project-control-map.json"
  echo "CREATED $DEST/project-control-map.json from example"
else
  echo "KEEP existing $DEST/project-control-map.json"
fi
cp "$SRC/project-control-map.example.json" "$DEST/project-control-map.example.json"
echo "INSTALLED dual-link -> $DEST"
echo "SOURCE $SRC"
