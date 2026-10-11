#!/usr/bin/env bash
# broker-tests.sh — targeted functional tests for the trusted promotion broker.
#
# One throwaway repo tree under /var/tmp; the broker is started on a throwaway socket
# (same uid here — this proves FUNCTIONAL correctness only, never an independent
# identity boundary). It asserts that the broker validates and applies through the
# central gate, and that invalid/unsafe requests are refused.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AEGL_ROOT="$(cd "$SELF_DIR/.." && pwd)"
CORE="$AEGL_ROOT/recovery/promotion_core.py"
BROKER="$AEGL_ROOT/recovery/promotion_broker.py"

ST="$(mktemp -d /var/tmp/aegl-broker-tests-XXXXXX)" || { echo "mktemp failed"; exit 2; }
PROOT="$ST/projects"; TROOT="$ST/tasks"; SOCK="$ST/broker.sock"
mkdir -p "$PROOT" "$TROOT"
PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
cleanup(){ [ -n "${BPID:-}" ] && kill "$BPID" 2>/dev/null; wait "${BPID:-}" 2>/dev/null; chmod -R u+w "$ST" 2>/dev/null; rm -rf "$ST"; }
trap cleanup EXIT

manifest(){ ( cd "$1" && find . -name .git -prune -o -type f -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum 2>/dev/null ); }

# make_task <id> <project-dir> <branch> <setup-cmd-run-in-worktree>
make_task(){
  local id="$1" proj="$2" branch="$3" setup="$4"
  local td wt
  td="$TROOT/$id"; wt="$td/worktree"
  mkdir -p "$td"
  git -C "$proj" worktree add -q -b "$branch" "$wt" HEAD || return 1
  ( cd "$wt" && eval "$setup" )
  manifest "$wt" > "$td/verify.manifest"
  printf 'PASS\n' > "$td/verify.status"
  python3 - "$td/task.json" "$id" "$proj" "$wt" "$branch" <<'PY'
import json,sys
p,id_,proj,wt,branch=sys.argv[1:6]
json.dump({"id":id_,"project":proj,"name":id_,"worktree":wt,"branch":branch}, open(p,"w"), indent=2)
PY
}

ask(){ python3 "$BROKER" client --socket "$SOCK" --task "$1" --op "${2:-promote}" 2>/dev/null; }
decision(){ printf '%s' "$1" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("decision",""))
except Exception: print("PARSE_ERROR")' 2>/dev/null; }

# --- fixtures ---------------------------------------------------------------- #
git -C "$PROOT" init -q 2>/dev/null || true
# allowed project (name in the allowed set)
mkdir -p "$PROOT/Google-Android-Agent-Development-Stack"
git -C "$PROOT/Google-Android-Agent-Development-Stack" init -q
( cd "$PROOT/Google-Android-Agent-Development-Stack" && echo base > README.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm base )
# disallowed-project fixture (name NOT in the allowed set)
mkdir -p "$PROOT/Testapp"
git -C "$PROOT/Testapp" init -q
( cd "$PROOT/Testapp" && echo base > README.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm base )

APP="$PROOT/Google-Android-Agent-Development-Stack"

# --- start broker (same uid; FUNCTIONAL test only) --------------------------- #
AEGL_BROKER_SOCKET="$SOCK" AEGL_TASKS_ROOT="$TROOT" PROJECTS_ROOT="$PROOT" \
  python3 "$BROKER" serve --socket "$SOCK" >"$ST/broker.log" 2>&1 &
BPID=$!
for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
[ -S "$SOCK" ] || { echo "broker did not start"; cat "$ST/broker.log"; exit 2; }
echo "broker up (pid $BPID, socket $SOCK)"

# 1. legitimate change -> APPLIED and merged
make_task t1 "$APP" aegl-task/t1 'echo hello > feature.txt'
r="$(ask t1)"; d="$(decision "$r")"
[ "$d" = APPLIED ] && ok "legitimate promotion APPLIED" || no "legitimate promotion ($d: $r)"
git -C "$APP" cat-file -e HEAD:feature.txt 2>/dev/null && ok "change merged into the project" || no "change not merged"

# 2. validate-only does not modify the target
make_task t2 "$APP" aegl-task/t2 'echo two > two.txt'
r="$(ask t2 validate)"; d="$(decision "$r")"
[ "$d" = VALIDATED ] && ok "validate-only returns VALIDATED" || no "validate-only ($d)"
git -C "$APP" cat-file -e HEAD:two.txt 2>/dev/null && no "validate modified the target" || ok "validate did not modify the target"

# 3. unsupported op
r="$(ask t2 rm -rf / 2>/dev/null)"; d="$(decision "$r")"
[ "$d" = REJECTED ] && ok "unsupported op REJECTED" || no "unsupported op ($d)"

# 4. unknown task
r="$(ask does-not-exist)"; d="$(decision "$r")"
[ "$d" = REJECTED ] && ok "unknown task REJECTED" || no "unknown task ($d)"

# 5. task_id traversal
r="$(python3 "$BROKER" client --socket "$SOCK" --task '../escape' --op promote 2>/dev/null)"; d="$(decision "$r")"
[ "$d" = REJECTED ] && ok "task_id traversal REJECTED" || no "task_id traversal ($d)"

# 6. disallowed project target (Testapp) -> REJECTED, target unchanged
make_task t6 "$PROOT/Testapp" aegl-task/t6 'echo six > six.txt'
r="$(ask t6)"; d="$(decision "$r")"
[ "$d" = REJECTED ] && ok "disallowed project REJECTED" || no "disallowed project ($d)"
git -C "$PROOT/Testapp" cat-file -e HEAD:six.txt 2>/dev/null && no "disallowed project was modified" || ok "disallowed project unchanged"

# 7. modified after verify -> REJECTED
make_task t7 "$APP" aegl-task/t7 'echo seven > seven.txt'
echo tampered >> "$TROOT/t7/worktree/seven.txt"
r="$(ask t7)"; d="$(decision "$r")"
[ "$d" = REJECTED ] && ok "modified_after_verify REJECTED" || no "modified_after_verify ($d)"
git -C "$APP" cat-file -e HEAD:seven.txt 2>/dev/null && no "tampered change merged" || ok "tampered change not merged"

# 8. generated/secret content -> REJECTED
make_task t8 "$APP" aegl-task/t8 'mkdir -p build && echo x > build/app.class'
r="$(ask t8)"; d="$(decision "$r")"
[ "$d" = REJECTED ] && ok "generated/secret REJECTED" || no "generated/secret ($d)"

# 9. serialization: two more promotions both apply cleanly
make_task t9 "$APP" aegl-task/t9 'echo nine > nine.txt'
make_task t10 "$APP" aegl-task/t10 'echo ten > ten.txt'
d9="$(decision "$(ask t9)")"; d10="$(decision "$(ask t10)")"
[ "$d9" = APPLIED ] && [ "$d10" = APPLIED ] && ok "serialized promotions both APPLIED" || no "serialization ($d9/$d10)"

echo "BROKER_TESTS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
