#!/usr/bin/env bash
# Stage 3.4 fixed boundary matrix (targeted).
#
# Denial/allowed probes exit 0 ONLY when the operation was correctly DENIED, and
# exit non-zero when it actually succeeded — so a successful write/read always
# fails the case. Adversarial probes run through the trusted-controller channel.
set -uo pipefail
export AEGL_TRUSTED_CONTROLLER=1

AEGL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK="$AEGL/bin/aegl-task"
export AEGL_STATE_HOME="${MATRIX_STATE:-$(mktemp -d /tmp/aegl-matrix-XXXXXX)}"
export AEGL_TASKS_ROOT="$AEGL_STATE_HOME/tasks"
export AEGL_CONTROLLER_TOKEN_FILE="$AEGL_STATE_HOME/controller.token"
printf 'matrix-controller-%s\n' "$RANDOM" > "$AEGL_CONTROLLER_TOKEN_FILE"
chmod 600 "$AEGL_CONTROLLER_TOKEN_FILE"
export AEGL_CONTROLLER_TOKEN="$(<"$AEGL_CONTROLLER_TOKEN_FILE")"

pass=0; fail=0
ok() { pass=$((pass+1)); printf 'PASS  %s\n' "$1"; }
no() { fail=$((fail+1)); printf 'FAIL  %s\n' "$1"; }

T=$(mktemp -d /tmp/aegl-target-XXXXXX); TARGET="$T/DemoProject"
mkdir -p "$TARGET/src" "$TARGET/scripts"
echo "hello" > "$TARGET/src/app.txt"
printf '#!/bin/sh\nexit 0\n' > "$TARGET/scripts/run-tests.sh"; chmod +x "$TARGET/scripts/run-tests.sh"
echo "build/" > "$TARGET/.gitignore"
( cd "$TARGET" && git init -q && git config user.email m@m.invalid && git config user.name M && git add -A && git commit -qm base )

start() { bash "$TASK" task start "$TARGET" "$1" 2>&1 | sed -n 's/^TASK_STARTED id=//p'; }
wt()    { python3 -c "import json;print(json.load(open('$AEGL_TASKS_ROOT/$1/task.json'))['worktree'])"; }
# denied <id> <probe-cmd>: probe exits 0 iff DENIED -> pass
denied() { bash "$TASK" controller probe "$1" "$2" >/dev/null 2>&1 && ok "$3" || no "$3"; }

# ---- positive: legit change verifies and promotes, canonical stays clean ----
id=$(start pos); printf 'world\n' >> "$(wt "$id")/src/app.txt"
bash "$TASK" task verify "$id" >/dev/null 2>&1 && bash "$TASK" task promote "$id" >/dev/null 2>&1 \
  && grep -q world "$TARGET/src/app.txt" && ok "positive: promote applied" || no "positive: promote applied"

# ---- N1 canonical write denied (fails if the write succeeds) ----
id=$(start n1)
denied "$id" "if echo x > '$TARGET/src/app.txt' 2>/dev/null; then exit 1; else exit 0; fi" "N1 canonical write denied"
bash "$TASK" task discard "$id" >/dev/null 2>&1

# ---- N2 home write denied ----
id=$(start n2)
denied "$id" "if echo x > '$HOME/.aegl_probe' 2>/dev/null; then exit 1; else exit 0; fi" "N2 home write denied"
bash "$TASK" task discard "$id" >/dev/null 2>&1

# ---- N10 host credential path UNREADABLE ----
id=$(start n10)
denied "$id" "test ! -r '$HOME/.commandcode/auth.json'" "N10 credential unreadable"
bash "$TASK" task discard "$id" >/dev/null 2>&1

# ---- N11 env whitelist (a secret exported in the parent must not leak) ----
export AEGL_LEAK_PROBE="leak-$RANDOM"
id=$(start n11)
denied "$id" "test -z \"\$AEGL_LEAK_PROBE\"" "N11 env whitelist enforced"
bash "$TASK" task discard "$id" >/dev/null 2>&1

# ---- N9 docker socket not writable ----
id=$(start n9)
denied "$id" "test ! -w /var/run/docker.sock" "N9 docker socket not writable"
bash "$TASK" task discard "$id" >/dev/null 2>&1

# ---- N3 symlink escape rejected ----
id=$(start n3); ln -s /etc/passwd "$(wt "$id")/escape-link"
bash "$TASK" task verify "$id" >/dev/null 2>&1 && bash "$TASK" task promote "$id" >/dev/null 2>&1 \
  && no "N3 symlink escape rejected" || ok "N3 symlink escape rejected"
bash "$TASK" task discard "$id" >/dev/null 2>&1

# ---- N4 generated artifact rejected ----
id=$(start n4); mkdir -p "$(wt "$id")/build"; printf 'x\n' > "$(wt "$id")/build/out.bin"
bash "$TASK" task verify "$id" >/dev/null 2>&1 && bash "$TASK" task promote "$id" >/dev/null 2>&1 \
  && no "N4 generated artifact rejected" || ok "N4 generated artifact rejected"
bash "$TASK" task discard "$id" >/dev/null 2>&1

# ---- N4b secret rejected ----
id=$(start n4b); printf 'k\n' > "$(wt "$id")/secrets.json"
bash "$TASK" task verify "$id" >/dev/null 2>&1 && bash "$TASK" task promote "$id" >/dev/null 2>&1 \
  && no "N4b secret rejected" || ok "N4b secret rejected"
bash "$TASK" task discard "$id" >/dev/null 2>&1

# ---- N5 deleted project body rejected ----
id=$(start n5); git -C "$(wt "$id")" rm -q src/app.txt
bash "$TASK" task verify "$id" >/dev/null 2>&1 && bash "$TASK" task promote "$id" >/dev/null 2>&1 \
  && no "N5 deleted body rejected" || ok "N5 deleted body rejected"
bash "$TASK" task discard "$id" >/dev/null 2>&1

# ---- N12 ignored file present rejected ----
id=$(start n12); mkdir -p "$(wt "$id")/build"; printf 'x\n' > "$(wt "$id")/build/ignored.bin"
bash "$TASK" task verify "$id" >/dev/null 2>&1 && bash "$TASK" task promote "$id" >/dev/null 2>&1 \
  && no "N12 ignored file rejected" || ok "N12 ignored file rejected"
bash "$TASK" task discard "$id" >/dev/null 2>&1

# ---- N13 modified-after-verify rejected ----
id=$(start n13)
printf 'v\n' >> "$(wt "$id")/src/app.txt"
bash "$TASK" task verify "$id" >/dev/null 2>&1
printf 'sneak\n' >> "$(wt "$id")/src/app.txt"     # modify after verify
bash "$TASK" task promote "$id" >/dev/null 2>&1 \
  && no "N13 modified-after-verify rejected" || ok "N13 modified-after-verify rejected"
bash "$TASK" task discard "$id" >/dev/null 2>&1

# ---- N6 disabled hook: enforcement must not depend on hooks ----
id=$(start n6); mkdir -p "$(wt "$id")/build"; printf 'x\n' > "$(wt "$id")/build/out.bin"
AEGL_DISABLE_HOOKS=1 bash "$TASK" task verify "$id" >/dev/null 2>&1 && AEGL_DISABLE_HOOKS=1 bash "$TASK" task promote "$id" >/dev/null 2>&1 \
  && no "N6 disabled hook fails closed" || ok "N6 disabled hook fails closed"
bash "$TASK" task discard "$id" >/dev/null 2>&1

# ---- N7 failed sandbox startup fails closed ----
id=$(start n7)
BWRAP=/nonexistent/bwrap bash "$TASK" task verify "$id" >/dev/null 2>&1 \
  && no "N7 sandbox fail-closed" || ok "N7 sandbox fail-closed"
bash "$TASK" task discard "$id" >/dev/null 2>&1

# ---- N8 git metadata mutation: attempted INSIDE the boundary and must be denied ----
id=$(start n8)
denied "$id" "if git -C '$(wt "$id")' config user.email evil@x.invalid 2>/dev/null; then exit 1; else exit 0; fi" "N8 git metadata mutation denied"
[ "$(git -C "$TARGET" config user.email)" = "m@m.invalid" ] && ok "N8 canonical git config unchanged" || no "N8 canonical git config unchanged"
bash "$TASK" task discard "$id" >/dev/null 2>&1

# ---- lifecycle ----
left=$(find "$AEGL_TASKS_ROOT" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
[ "$left" = 0 ] && ok "lifecycle: no worktree/output retained" || no "lifecycle: $left task dirs retained"
[ "$(git -C "$TARGET" worktree list | tail -n +2 | wc -l)" = 0 ] && ok "lifecycle: no stray worktrees" || no "lifecycle: stray worktrees"

echo "MATRIX_RESULT passed=$pass failed=$fail"
rm -rf "$T" "$AEGL_STATE_HOME"
exit $(( fail>0 ? 1 : 0 ))
