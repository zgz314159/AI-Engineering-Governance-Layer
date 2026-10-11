#!/usr/bin/env bash
# Focused checks for THIS round's change only: the launcher's mount + privilege-drop order
# and the precise trial cleanup. It does NOT re-run uid-launch-tests or the 20+ prior checks.
set -u
AEGL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCH="$AEGL_ROOT/bin/aegl-hermes-sandbox"
INST="$AEGL_ROOT/recovery/install-model-broker.sh"
PASS=0; FAIL=0
ok(){ printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
no(){ printf '  FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

# --- the argv from the ONE builder --------------------------------------------- #
ARGV="$(python3 - "$AEGL_ROOT/recovery/sandbox_spec.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ss", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
argv = m.build(bwrap="/usr/bin/bwrap", uid="994", gid="972", run="/run/aegl-model/t",
               wt="/tmp/wt", scr="/tmp/scr", runtime="/home/zhong/.hermes/hermes-agent",
               tools="/home/zhong/.hermes/tools", entry="/home/zhong/.local/bin/hermes",
               installs="/home/zhong/.hermes/installs", guard_src="/g", guard_dest="/home/zhong/g",
               contract_package="/pkg", setpriv="/usr/bin/setpriv", info_fd="", hermes_args=["hermes"])["argv"]
print("\n".join(argv))
PY
)"
ARGV_ONE="$(printf '%s\n' "$ARGV" | tr '\n' ' ')"
has(){ printf '%s\n' "$ARGV" | grep -qxF -- "$1"; }
pair(){ printf '%s' "$ARGV_ONE" | grep -qF -- "$1 "; }

# no user namespace / no pre-mount uid drop (the OLD fd path)
has "--unshare-all" && no "argv still has --unshare-all" || ok "argv has no --unshare-all"
has "--unshare-user" && no "argv still has --unshare-user" || ok "argv has no --unshare-user (host ids preserved)"
has "--uid" && no "argv still has --uid (would drop before mounting)" || ok "argv has no --uid/--gid drop"
printf '%s\n' "$ARGV" | grep -q 'ro-bind-fd' && no "argv still uses --ro-bind-fd" || ok "argv has no --ro-bind-fd"
has "--unshare-pid" && ok "argv unshares pid" || no "argv does not unshare pid"
has "--unshare-net" && ok "argv unshares net (no egress)" || no "argv does not unshare net"

# the runtime source is a PLAIN root ro-bind (root reads the 0750 source directly)
pair "--ro-bind /home/zhong/.hermes/hermes-agent" && ok "runtime source is a plain --ro-bind" || no "runtime source is not a plain ro-bind"
pair "--ro-bind /pkg" && ok "contract package is a plain ro-bind" || no "contract package not ro-bound"
pair "--bind /tmp/wt" && ok "task worktree stays writable" || no "worktree bind missing"

# the FIRST in-sandbox process is the trusted drop entry, then the runner
pair "/usr/bin/setpriv" && ok "trusted drop entry (setpriv) is the first in-sandbox command" || no "setpriv not in argv"
for f in --reuid --regid --clear-groups --no-new-privs --inh-caps=-all --ambient-caps=-all; do
  has "$f" && ok "drop flag present: $f" || no "drop flag missing: $f"
done

# --- launcher + cleanup wiring -------------------------------------------------- #
grep -q 'python3 "$EXEC_SPEC" "$SPEC"' "$LAUNCH" && ok "launcher execs the spec (plain mounts)" || no "launcher not using EXEC_SPEC"
grep -q 'bind_fd_exec' "$LAUNCH" && no "launcher still references bind_fd_exec" || ok "launcher no longer references bind_fd_exec"
grep -q 'SETPRIV="/usr/bin/setpriv"' "$LAUNCH" && ok "launcher pins the trusted drop entry" || no "launcher does not pin setpriv"
grep -q 'cleanup(){ kill "\$BPID" 2>/dev/null; rm -rf "\$RUN"; }' "$LAUNCH" && ok "launcher cleans its run dir on exit" || no "launcher does not clean RUN"
grep -q 'trap cleanup EXIT TERM INT' "$LAUNCH" && ok "launcher traps EXIT/TERM/INT" || no "launcher trap missing"
grep -q 'rm -rf "\$ST" "/run/aegl-model/\$TID"' "$INST" && ok "installer removes this task's exact run dir" || no "installer does not remove the run dir"
grep -q 'trap cleanup_trial RETURN EXIT TERM INT' "$INST" && ok "installer cleans on normal/failure/TERM" || no "installer trap incomplete"

echo "MOUNT_DROP_TESTS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
