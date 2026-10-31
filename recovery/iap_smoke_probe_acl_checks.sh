#!/usr/bin/env bash
# iap_smoke_probe_acl_checks.sh — offline regression for the S0 sandbox-identity probe.
#
# Regression for the ACL-blind host `test` bug (2026-10-31, IAP-SMOKE-001):
# the prep probe must decide access the way the kernel does for the aegl-ai sandbox
# identity — via access(2), which honors POSIX ACLs — and must NOT shell out to the
# host `test` binary. Some hosts ship a Rust/uutils coreutils `test` that reads mode
# bits only; it ignores ACLs and so false-negatively rejects the aegl-ai traversal
# ACL on the task root, aborting stage=probe with probe_traverse even though
# `getfacl -e` shows `user:aegl-ai:--x #effective:--x`.
#
# Offline: no root, no aegl-ai, no host change. The deepest check (aegl-ai on a
# root-owned task root through a named-user ACL) needs root and stays NOT_RUN here.
set -uo pipefail
PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRV="$PKG/bin/run_smoke.sh"
RC=0
log() { printf '%s\n' "$*"; }
check() { if [ "$2" = "$3" ]; then log "PASS $1 ($2)"; else log "FAIL $1 got='$2' want='$3'"; RC=1; fi; }

# --- 1. the probe no longer execs the ACL-blind host `test` as aegl-ai ------------- #
check "B1.no_runuser_test"    "$(grep -c 'runuser -u aegl-ai -- test' "$DRV")" "0"
check "B2.no_runuser_bracket" "$(grep -c 'runuser -u aegl-ai -- \[' "$DRV")" "0"
check "B3.acl_aware_access"   "$(grep -c 'os\.access(sys\.argv' "$DRV")" "1"
check "B4.pam_free_setpriv"   "$(grep -c 'setpriv --reuid' "$DRV")" "1"
check "B5.mask_pinned"        "$(grep -c 'setfacl -m m::rx' "$DRV")" "2"
check "B6.effective_asserted" "$(grep -c '#effective:' "$DRV")" "2"

# --- 2. mechanism proof (offline, decisive): access(2) vs mode-bit-only ------------ #
# The dynamic loader's own access("/etc/ld.so.preload", R_OK) is not X_OK, so matching
# on X_OK/faccessat cleanly separates an ACL-aware check from a mode-bit-only one.
if command -v strace >/dev/null 2>&1; then
  mech_py="$(strace -f -e trace=access,faccessat,faccessat2 /usr/bin/python3 -I -c \
      'import os; os.access("/var/tmp", os.X_OK)' 2>&1 | grep -cE 'X_OK|faccessat')"
  check "B7.acl_aware_uses_access2" "$([ "${mech_py:-0}" -ge 1 ] && echo yes || echo no)" "yes"
  host_test="$(command -v test)"
  mech_t="$(strace -f -e trace=access,faccessat,faccessat2 "$host_test" -x /var/tmp 2>&1 | grep -cE 'X_OK|faccessat')"
  check "B8.host_test_is_acl_blind" "$([ "${mech_t:-0}" -eq 0 ] && echo yes || echo no)" "yes"
else
  log "NOT_RUN B7/B8 (strace unavailable)"
fi

# --- 3. functional sanity of the ACL-aware check (mode-based, offline) -------------- #
D="$(mktemp -d /var/tmp/iap-aclchk-XXXXXX)"; trap 'rm -rf "$D"' EXIT
chmod 0755 "$D"; : > "$D/f"; chmod 0644 "$D/f"
ok_x() { /usr/bin/python3 -I -c 'import os,sys; sys.exit(0 if os.access(sys.argv[1], os.X_OK) else 1)' "$1"; }
ok_r() { /usr/bin/python3 -I -c 'import os,sys; sys.exit(0 if os.access(sys.argv[1], os.R_OK) else 1)' "$1"; }
check "B9.dir_exec_allowed"   "$(ok_x "$D"   && echo yes || echo no)" "yes"
check "B10.file_exec_denied"  "$(ok_x "$D/f" && echo yes || echo no)" "no"
check "B11.file_read_allowed" "$(ok_r "$D/f" && echo yes || echo no)" "yes"

# --- 4. deepest check needs root and stays NOT_RUN here ---------------------------- #
log "NOT_RUN B12.cross-uid-acl (aegl-ai on a root-owned task root via named-user ACL; root-only)"
log "SUMMARY rc=$RC"; exit "$RC"
