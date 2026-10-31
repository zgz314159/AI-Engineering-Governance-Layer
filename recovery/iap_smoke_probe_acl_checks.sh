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

# --- 3b. narrowed ancestor change: only $TRAVERSE_APPROVED, mask preserved ---------- #
# U1: an UNapproved blocker is refused AND that directory is left untouched.
mkdir -p "$D/U1/x/y"
TRV="$D/trv1.log"; : > "$TRV"
u1="$(env DRV="$DRV" TRV="$TRV" BLK="$D/U1" bash -c '
  set -uo pipefail
  source "$DRV"; FAIL_MARK=/nonexistent; CURRENT_STAGE=unit
  setfacl() { printf "%s %s\n" "$2" "$3" >> "$TRV"; }
  ai_access() { case "$2" in "$BLK") return 1 ;; *) return 0 ;; esac; }
  ensure_required_traverse "$BLK/x/y" && echo DONE
' 2>&1; echo "rc=$?")"
check "C1.unapproved_refused"   "$(grep -c 'traverse_blocked' <<< "$u1")" "1"
check "C2.unapproved_nonzero"   "$(grep -c 'rc=[1-9]' <<< "$u1")" "1"
check "C3.unapproved_untouched" "$(grep -c . "$TRV")" "0"

# U2: applying the approved change preserves the mask and every other entry (REAL ACL,
# file-owner privileges), and the only difference is the added aegl-ai x entry.
mkdir -p "$D/U2"; chmod 0755 "$D/U2"; setfacl -m u:nobody:--x "$D/U2"
u2b="$(getfacl -p "$D/U2")"
env DRV="$DRV" T="$D/U2" bash -c '
  set -uo pipefail
  source "$DRV"; FAIL_MARK=/nonexistent; CURRENT_STAGE=unit
  TRAVERSE_APPROVED="$T"; ai_access() { return 0; }
  grant_approved_traverse' >/dev/null 2>&1
u2a="$(getfacl -p "$D/U2")"
check "C4.approved_added"    "$(grep -cE '^user:aegl-ai:--x$' <<< "$u2a")" "1"
check "C5.mask_unchanged"    "$(grep -cE '^mask::r-x$' <<< "$u2a")" "1"
check "C6.other_entry_kept"  "$(grep -cE '^user:nobody:--x$' <<< "$u2a")" "1"
check "C7.only_aegl_change" \
  "$(diff <(printf '%s\n' "$u2b" | grep -vE '^user:aegl-ai:') \
          <(printf '%s\n' "$u2a" | grep -vE '^user:aegl-ai:') >/dev/null && echo same || echo differ)" "same"

# U3: a mask that does not already allow x is refused, and nothing changes.
mkdir -p "$D/U3"; chmod 0640 "$D/U3"; setfacl -m u:nobody:r-- "$D/U3"
u3b="$(getfacl -p "$D/U3")"
u3="$(env DRV="$DRV" T="$D/U3" bash -c '
  set -uo pipefail
  source "$DRV"; FAIL_MARK=/nonexistent; CURRENT_STAGE=unit
  TRAVERSE_APPROVED="$T"; ai_access() { return 0; }
  grant_approved_traverse' 2>&1; echo "rc=$?")"
check "C8.mask_no_x_refused"   "$(grep -c 'traverse_mask_no_x' <<< "$u3")" "1"
check "C9.mask_no_x_unchanged" "$([ "$u3b" = "$(getfacl -p "$D/U3")" ] && echo same || echo differ)" "same"

# U4: a conflicting existing aegl-ai entry is refused, and nothing changes.
mkdir -p "$D/U4"; chmod 0755 "$D/U4"; setfacl -m u:aegl-ai:rwx "$D/U4"
u4b="$(getfacl -p "$D/U4")"
u4="$(env DRV="$DRV" T="$D/U4" bash -c '
  set -uo pipefail
  source "$DRV"; FAIL_MARK=/nonexistent; CURRENT_STAGE=unit
  TRAVERSE_APPROVED="$T"; ai_access() { return 0; }
  grant_approved_traverse' 2>&1; echo "rc=$?")"
check "C10.conflict_refused"   "$(grep -c 'traverse_conflict' <<< "$u4")" "1"
check "C11.conflict_unchanged" "$([ "$u4b" = "$(getfacl -p "$D/U4")" ] && echo same || echo differ)" "same"

# U5: a bad target path fails closed instead of silently succeeding.
bad="$( ( source "$DRV"; FAIL_MARK=/nonexistent; CURRENT_STAGE=unit; ensure_required_traverse /no/such/path ) 2>&1; echo "rc=$?" )"
check "C12.bad_target_fails"   "$(grep -c 'rc=[1-9]' <<< "$bad")" "1"
check "C13.bad_target_reason"  "$(grep -c 'traverse_target' <<< "$bad")" "1"

# --- 3c. static wiring: narrowed, single approved change, honest label -------------- #
check "D1.approved_dir_exact"      "$(grep -c 'TRAVERSE_APPROVED="/home/zhong"' "$DRV")" "1"
check "D2.chain_check_commondir"   "$(grep -c 'ensure_required_traverse "\$commondir"' "$DRV")" "1"
check "D3.chain_check_gitdir"      "$(grep -c 'ensure_required_traverse "\$gitdir"' "$DRV")" "1"
check "D4.mask_preserving_grant"   "$(grep -c 'setfacl -n -m u:aegl-ai:x' "$DRV")" "1"
check "D5.no_generic_autogrant"    "$(grep -c 'ensure_traverse()' "$DRV")" "0"
check "D6.probe_full_chain"        "$(grep -c 'chain_blocker' "$DRV")" "2"
check "D7.probe_precedes_contract" "$(grep -c 'PREP_STAGES=(preflight baseline worktree permissions probe contract binding register ready)' "$DRV")" "1"
check "D8.label_not_overclaiming"  "$(grep -c 'traverse-verified' "$DRV")" "0"

# --- 4. checks needing a real dropped identity / root stay NOT_RUN ------------------ #
log "NOT_RUN B12.cross-uid-acl (aegl-ai on a root-owned task root via named-user ACL)"
log "NOT_RUN C14.approved-grant-live (real /home/zhong change + real dropped identity; root-only)"
log "NOT_RUN D9.contract-register-not-run (requires the full root prep)"
log "SUMMARY rc=$RC"; exit "$RC"
