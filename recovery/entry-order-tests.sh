#!/usr/bin/env bash
# Focused check for THIS round only: the launch ORDER and parameters. It uses the ACTUAL
# generated spec, inspects the real launcher, and runs host-policy probes for real.
set -u
AEGL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCH="$AEGL_ROOT/bin/aegl-hermes-sandbox"
DV="$AEGL_ROOT/recovery/drop_verify.py"
PASS=0; FAIL=0
ok(){ printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
no(){ printf '  FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

# === 1. actual spec: bwrap runs as aegl-ai, no inner capability drop ================ #
ARGV="$(python3 - "$AEGL_ROOT/recovery/sandbox_spec.py" <<'PY'
import importlib.util, sys
m = importlib.util.module_from_spec(importlib.util.spec_from_file_location("ss", sys.argv[1]))
importlib.util.spec_from_file_location("ss", sys.argv[1]).loader.exec_module(m)
a = m.build(bwrap="/usr/bin/bwrap", uid="994", gid="972", run="/run/t", wt="/tmp/wt",
            scr="/tmp/scr", runtime="/run/t/src/runtime", tools="/run/t/src/tools",
            entry="/run/t/src/entry", installs="/run/t/src/installs", guard_src="/run/t/src/guard",
            guard_dest="/home/zhong/g", contract_package="/pkg", hermes_args=["hermes"])["argv"]
print("\n".join(a))
PY
)"
ONE="$(printf '%s\n' "$ARGV" | tr '\n' ' ')"
grep -q -- '--unshare-user' <<<"$ONE" && ok "bwrap uses its AppArmor-permitted user namespace (--unshare-user)" || no "--unshare-user missing"
grep -q -- '--cap-drop' <<<"$ONE" && no "argv still has capability options" || ok "argv has no capability options"
grep -q -- '--cap-add' <<<"$ONE" && no "argv still adds capabilities" || ok "argv adds no capabilities"
grep -q -- 'setpriv' <<<"$ONE" && no "argv still switches identity inside bwrap" || ok "no identity switch inside bwrap"
grep -q -- 'drop_verify' <<<"$ONE" && no "argv still runs the drop check inside bwrap" || ok "no drop check inside bwrap"
grep -q -- 'bash /run/t/sandbox-run.sh' <<<"$ONE" && ok "the first in-sandbox process is just the runner" || no "runner is not the first in-sandbox process: $ONE"
grep -q -- '--ro-bind /run/t/src/runtime /home/zhong/.hermes/hermes-agent' <<<"$ONE" && ok "runtime source is the private-ns alias (not the real HOME path)" || no "runtime source is not the alias"

# === 2. launcher order: prep aliases -> drop -> bwrap ============================== #
grep -q 'unshare --mount --propagation private -- bash "\$RUN/prep.sh"' "$LAUNCH" && ok "the whole chain runs in a private mount namespace" || no "no private mount namespace"
for s in hermes-agent tools entry installs guard; do :; done
[ "$(grep -c 'mount --bind' "$LAUNCH")" -ge 4 ] && ok "root bind-mounts the declared sources to task-dir aliases" || no "alias bind-mounts missing"
SP="$(grep -n "exec '\$SETPRIV'" "$LAUNCH" | head -1 | cut -d: -f1)"
BW="$(grep -n "python3 '\$EXEC_SPEC'" "$LAUNCH" | head -1 | cut -d: -f1)"
{ [ -n "$SP" ] && [ -n "$BW" ] && [ "$SP" -lt "$BW" ]; } && ok "setpriv drop precedes bwrap in the prep script ($SP<$BW)" || no "the drop does not precede bwrap"
for f in --clear-groups --no-new-privs --bounding-set=-all --inh-caps=-all --ambient-caps=-all; do
  grep -q -- "$f" "$LAUNCH" && ok "host drop flag present: $f" || no "host drop flag missing: $f"
done
[ "$(stat -c '%a' /usr/bin/bwrap)" = 755 ] && ok "bwrap is a plain non-setuid binary (755)" || no "bwrap perms are not 755"
grep -q -- '--ro-bind-fd' "$LAUNCH" && no "the old fd-mount path is still referenced" || ok "no --ro-bind-fd path remains"

# === 3. host-policy compatibility probes (recorded as evidence, not aegl-ai acceptance) #
bwrap --unshare-user --ro-bind / / --proc /proc --dev /dev -- /bin/sh -c 'id -u >/dev/null' 2>/dev/null \
  && ok "host policy: unprivileged bwrap userns IS permitted here" || no "host policy: bwrap userns not permitted"
unshare --user --map-root-user true 2>/dev/null \
  && no "host policy: generic unshare --user unexpectedly works" \
  || ok "host policy: generic 'unshare --user' is refused (bwrap-specific permission)"

# === 4. the read-only check still fails closed ===================================== #
OUT="$(python3 "$DV" --uid "$(id -u)" --gid "$(id -g)" -- /bin/echo RAN 2>&1)"; RC=$?
{ [ "$RC" != 0 ] && grep -q 'DROP_HANDOFF_FAIL' <<<"$OUT"; } && ok "read-only check still refuses when the host state is wrong" || no "read-only check did not fail closed ($RC): $OUT"
grep -q 'RAN' <<<"$OUT" && no "the command ran despite a failed check" || ok "nothing ran after a failed check"

echo "ENTRY_ORDER_TESTS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
