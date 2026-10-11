#!/usr/bin/env bash
# Targeted unit tests for the Stage 3 boundary fixes (single self-check run).
# Covers: real AI entry (process + children sandboxed), controller privilege
# escalation (token auth + token unreadable in-sandbox), RuleSync plan-only with
# conflict/partial-success reporting. A successful privileged action always fails a
# case (no `&& exit 9`).
set -uo pipefail
WT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK="$WT_DIR/bin/aegl-task"
AI="$WT_DIR/bin/aegl-ai"
export AEGL_STATE_HOME="$(mktemp -d /tmp/aegl-tests-XXXXXX)"
export AEGL_TASKS_ROOT="$AEGL_STATE_HOME/tasks"
export AEGL_CONTROLLER_TOKEN_FILE="$AEGL_STATE_HOME/controller.token"
printf 'operator-secret-%s\n' "$RANDOM" > "$AEGL_CONTROLLER_TOKEN_FILE"; chmod 600 "$AEGL_CONTROLLER_TOKEN_FILE"
TOKEN="$(cat "$AEGL_CONTROLLER_TOKEN_FILE")"
trusted_task(){ AEGL_CONTROLLER_TOKEN="$TOKEN" bash "$TASK" task "$@"; }
HOST_CRED="$HOME/.commandcode/auth.json"
# An out-of-tree worktree cannot infer the canonical projects dir; the operator sets it.
: "${PROJECTS_ROOT:?set PROJECTS_ROOT to the canonical projects directory}"
export PROJECTS_ROOT

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'PASS  %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL  %s\n' "$1"; }

T=$(mktemp -d /tmp/aegl-tgt-XXXXXX); TARGET="$T/Demo"
mkdir -p "$TARGET/scripts"; echo hi > "$TARGET/app.txt"; printf '#!/bin/sh\nexit 0\n' > "$TARGET/scripts/run-tests.sh"; chmod +x "$TARGET/scripts/run-tests.sh"
( cd "$TARGET" && git init -q && git config user.email m@m.invalid && git config user.name M && git add -A && git commit -qm base )
ID="$(bash "$TASK" task start "$TARGET" t1 2>&1 | sed -n 's/^TASK_STARTED id=//p')"
[ -n "$ID" ] || { echo "setup failed"; exit 2; }

# controller-authored in-sandbox check script (host paths expanded by the controller)
CHK="$T/scenario.sh"
cat > "$CHK" <<EOF
#!/bin/sh
canon_ro=\$( [ ! -w '$TARGET' ] && echo true || echo false )
cred_masked=\$( [ ! -r '$HOST_CRED' ] && echo true || echo false )
echo "PARENT sane=\$AEGL_AI_SANDBOX canonical_ro=\$canon_ro cred_masked=\$cred_masked pid=\$\$"
bash -c 'echo "CHILD sane=\$AEGL_AI_SANDBOX pid=\$\$"'
EOF
chmod +x "$CHK"

# ---- T1: real AI entry — the AI process AND its child run inside the sandbox ----
out="$(bash "$AI" run --task "$ID" --net off -- bash "$CHK" 2>&1)"
echo "$out" | grep -q 'PARENT sane=1 canonical_ro=true cred_masked=true' && ok "T1 parent sandboxed + canonical RO + creds masked" || no "T1 parent ($out)"
echo "$out" | grep -q 'CHILD sane=1' && ok "T1 child process also sandboxed" || no "T1 child ($out)"

# ---- T2: cloud/network mode fails before any credential copy ----
TASK_CRED="$AEGL_TASKS_ROOT/$ID/model-credential"
printf 'test-model-secret\n' > "$TASK_CRED"; chmod 600 "$TASK_CRED"
bash "$AI" run --task "$ID" --net cloud -- true >/dev/null 2>&1 && no "T2 cloud mode refused" || ok "T2 cloud/network mode fails closed"
[ ! -e "$AEGL_TASKS_ROOT/$ID/scratch/model-credential" ] && ok "T2 cloud refusal left no credential copy" || no "T2 credential copy remained"
bash "$AI" run --task "$ID" --net off -- bash -c "test -z \"\${AEGL_MODEL_CREDENTIAL_FILE:-}\" && test -z \"\$(cat '$TASK_CRED' 2>/dev/null)\"" >/dev/null 2>&1 \
  && ok "T2 offline AI cannot retrieve task credential" || no "T2 offline AI retrieved task credential"

# ---- T3: controller escalation requires the token ----
bash "$TASK" controller probe "$ID" "true" >/dev/null 2>&1 && no "T3 no-token rejected" || ok "T3 no-token rejected"
AEGL_CONTROLLER_TOKEN=wrong bash "$TASK" controller probe "$ID" "true" >/dev/null 2>&1 && no "T3 wrong-token rejected" || ok "T3 wrong-token rejected"
AEGL_CONTROLLER_TOKEN="$TOKEN" bash "$TASK" controller probe "$ID" "true" >/dev/null 2>&1 && ok "T3 valid-token accepted" || no "T3 valid-token accepted"

# ---- T4: the controller token secret is NOT retrievable inside the sandbox ----
# (masked via a /dev/null bind: the path exists but yields no content, so the secret
#  is unobtainable; a readable-but-empty path is not a leak)
AEGL_CONTROLLER_TOKEN="$TOKEN" bash "$TASK" controller probe "$ID" "test -z \"\$(cat '$AEGL_CONTROLLER_TOKEN_FILE' 2>/dev/null)\"" >/dev/null 2>&1 \
  && ok "T4 token secret not retrievable in-sandbox" || no "T4 token secret not retrievable in-sandbox"

# ---- T5: RuleSync plan writes nothing and reports global targets/conflicts ----
proj_state() { local d="$PROJECTS_ROOT/$1"; { for f in AGENTS.md CLAUDE.md; do [ -e "$d/$f" ] && sha256sum "$d/$f"; done; for x in .cursor rulesync.jsonc .rulesync; do [ -e "$d/$x" ] && echo "$x present"; done; } | sha256sum | awk '{print $1}'; }
declare -A before
for p in Google-Android-Agent-Development-Stack KeepLab-Relay AI-Engineering-Governance-Layer; do before[$p]="$(proj_state "$p")"; done
mkdir -p "$T/operator-home/.codex"
printf 'pre-existing instruction\n' > "$T/operator-home/.codex/AGENTS.md"
plan="$(HOME="$T/operator-home" bash "$TASK" boundary rulesync plan 2>&1)"; prc=$?
after_ok=1
for p in Google-Android-Agent-Development-Stack KeepLab-Relay AI-Engineering-Governance-Layer; do
  [ "${before[$p]}" = "$(proj_state "$p")" ] || after_ok=0
done
[ "$after_ok" = 1 ] && ok "T5 plan wrote nothing" || no "T5 plan wrote files"
echo "$plan" | grep -q 'global_rules=no' && ok "T5 cursor global unsupported reported" || no "T5 cursor global unsupported reported"
echo "$plan" | grep -q 'CONFLICT' && ok "T5 existing-file conflict reported" || no "T5 conflict reported"
echo "$plan" | grep -Fq "would write: $T/operator-home/.claude/CLAUDE.md" && ok "T5 Claude global path" || no "T5 Claude global path"
echo "$plan" | grep -Fq "would write: $T/operator-home/.codex/AGENTS.md" && ok "T5 Codex global path" || no "T5 Codex global path"
[ "$(cat "$T/operator-home/.codex/AGENTS.md")" = 'pre-existing instruction' ] && ok "T5 existing global rule unchanged" || no "T5 existing global rule changed"
[ "$prc" -ne 0 ] && ok "T5 unsupported/conflict => NOT_DONE (non-zero)" || no "T5 plan returned zero"

# ---- T6: promote/discard require controller authentication ----
printf 'candidate\n' >> "$(python3 -c "import json;print(json.load(open('$AEGL_TASKS_ROOT/$ID/task.json'))['worktree'])")/app.txt"
bash "$TASK" task verify "$ID" >/dev/null 2>&1 && ok "T6 candidate verified" || no "T6 candidate verify failed"
bash "$TASK" task promote "$ID" >/dev/null 2>&1 && no "T6 no-token promote rejected" || ok "T6 no-token promote rejected"
AEGL_CONTROLLER_TOKEN=wrong bash "$TASK" task promote "$ID" >/dev/null 2>&1 && no "T6 wrong-token promote rejected" || ok "T6 wrong-token promote rejected"
trusted_task promote "$ID" >/dev/null 2>&1 && grep -q candidate "$TARGET/app.txt" \
  && ok "T6 authenticated promote accepted" || no "T6 authenticated promote failed"
ID2="$(bash "$TASK" task start "$TARGET" t6-discard 2>&1 | sed -n 's/^TASK_STARTED id=//p')"
bash "$TASK" task discard "$ID2" >/dev/null 2>&1 && no "T6 no-token discard rejected" || ok "T6 no-token discard rejected"
trusted_task discard "$ID2" >/dev/null 2>&1 && ok "T6 authenticated discard accepted" || no "T6 authenticated discard accepted"
rm -rf "$T" "$AEGL_STATE_HOME"
echo "BOUNDARY_TESTS passed=$pass failed=$fail"
exit $(( fail>0 ? 1 : 0 ))
