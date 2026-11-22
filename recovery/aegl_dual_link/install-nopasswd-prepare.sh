#!/usr/bin/env bash
# One-shot installer: copy prepare wrapper to /usr/local/sbin and install sudoers.
# Requires a single interactive sudo password (or works with sudo -n after first auth).
# Does NOT relax sandbox, auto-approve Hermes, or broaden beyond this one binary.
set -euo pipefail
SRC_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
WRAPPER_SRC=$SRC_DIR/aegl-calendar-prepare
SUDOERS_SRC=$SRC_DIR/sudoers-aegl-calendar-prepare
DEST_WRAP=/usr/local/sbin/aegl-calendar-prepare
DEST_SUDO=/etc/sudoers.d/aegl-calendar-prepare

[ -f "$WRAPPER_SRC" ] || { echo "missing $WRAPPER_SRC" >&2; exit 1; }
[ -f "$SUDOERS_SRC" ] || { echo "missing $SUDOERS_SRC" >&2; exit 1; }

# Validate sudoers syntax before install
visudo -cf "$SUDOERS_SRC" || { echo "sudoers source failed visudo -cf" >&2; exit 1; }

echo "Installing $DEST_WRAP and $DEST_SUDO (needs sudo once)..."
sudo install -o root -g root -m 0755 "$WRAPPER_SRC" "$DEST_WRAP"
sudo install -o root -g root -m 0440 "$SUDOERS_SRC" "$DEST_SUDO"
sudo visudo -cf "$DEST_SUDO"

# Prior root prepare left some formal .git/objects/* owned by root:root 755,
# which blocks zhong from committing into linked worktrees (object prefix collision).
FORMAL_OBJECTS=/home/zhong/EXE/OfflineTaskCalendar_WPF/.git/objects
if [[ -d $FORMAL_OBJECTS ]]; then
  echo "Repairing root-owned object dirs under $FORMAL_OBJECTS ..."
  sudo find "$FORMAL_OBJECTS" -maxdepth 1 -user root -exec chown zhong:zhong {} +
fi

# Prove passwordless path. Wrapper exits non-zero on argc errors; do not use
# a pipe under `set -o pipefail` or a successful reach will look like failure.
out=$(sudo -n "$DEST_WRAP" 2>&1 || true)
if grep -q 'BLOCKED:' <<<"$out"; then
  echo "NOPASSWD_OK wrapper=$DEST_WRAP"
  echo "$out"
else
  echo "$out" >&2
  echo "INSTALL_DONE but sudo -n probe inconclusive — expected a BLOCKED: line from $DEST_WRAP" >&2
  exit 2
fi
echo "INSTALL_COMPLETE"
