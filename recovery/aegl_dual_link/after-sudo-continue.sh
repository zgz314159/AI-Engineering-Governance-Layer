#!/usr/bin/env bash
# Run in a real TTY (Command Code / gnome-terminal). One sudo password, then
# unattended prepare→submit→host-run for the next queued dual-link job.
set -euo pipefail
ROOT=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
OP=$ROOT/dual-link-operator.sh

# Install (or re-verify) narrow NOPASSWD prepare wrapper.
bash "$ROOT/install-nopasswd-prepare.sh"

# If queue is empty but a job was already submitted/completed by a parallel
# continue, do not invent work — report status and exit 0.
if [[ ! -f /home/zhong/.local/state/aegl-dual-link/queue.json ]] \
  || ! python3 -c 'import json,sys; q=json.load(open("/home/zhong/.local/state/aegl-dual-link/queue.json")); sys.exit(0 if q.get("items") else 1)'; then
  echo "QUEUE_EMPTY — nothing to continue. Recent jobs:"
  bash "$OP" status | sed -n '/Active \/ recent/,+12p'
  exit 0
fi

exec bash "$OP" continue
