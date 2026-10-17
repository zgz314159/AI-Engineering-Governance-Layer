#!/usr/bin/env bash
# DEPRECATED as a single chained pack.
# Use the three separate packs (do not chain prepare→switch in one sudo session):
#
#   recovery/host-identity-prepare.sh     # preflight once + registry + deps-wire
#   recovery/host-identity-cleanup.sh     # delete DELETE_CLEARED node_modules only
#   recovery/host-identity-switch-apply.sh  # after tip on main; --skip-preflight
#
# This file exits with instructions only.
set -euo pipefail
printf '%s\n' \
  "STOP_AT=use_separate_packs" \
  "Use host-identity-prepare.sh, then host-identity-cleanup.sh, then promote tip," \
  "then host-identity-switch-apply.sh — not this chained exec." >&2
exit 2
