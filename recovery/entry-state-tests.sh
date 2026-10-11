#!/usr/bin/env bash
# Focused check for THIS round only: the task-level install-state view + writable run state.
# Uses the ACTUAL generated argv and a path/metadata fixture. The fixture is explicitly NOT
# aegl-ai host acceptance (that needs root and stays NOT_RUN).
set -u
AEGL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok(){ printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
no(){ printf '  FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

T="$(mktemp -d)"; KEY="b178d76051535411"
GEN="$T/gen/$KEY"; VIEW="$T/view"; ST="$T/runstate"
mkdir -p "$GEN/environments/79024fc4" "$GEN/bootstrap" "$GEN/pm-runtime/generations/d5824bf8" "$GEN/inputs" \
         "$VIEW/$KEY/environments" \
         "$ST/home-sessions" "$ST/prof-logs"
: > "$GEN/environments/79024fc4/pyvenv.cfg"
: > "$GEN/pm-runtime/.prepare.lock"
echo '{"generation": "d5824bf8"}' > "$GEN/pm-runtime/selected.json"
printf '{"schema": 1, "packages": {"venv": {"environment": "%s/environments/79024fc4", "schema": "1"}}}\n' "$GEN" > "$GEN/facts.json"

# the metadata/mutable reuse the launcher performs (verbatim copy of the REAL verified state)
for entry in facts.json declined-packages.json inputs bootstrap pm-runtime; do
  [ -e "$GEN/$entry" ] && cp -a "$GEN/$entry" "$VIEW/$KEY/$entry"
done
cmp -s "$GEN/facts.json" "$VIEW/$KEY/facts.json" && ok "facts.json is reused verbatim (byte-identical, not forged)" || no "facts.json was altered"
[ -f "$VIEW/$KEY/pm-runtime/selected.json" ] && ok "pm-runtime selection is reused verbatim (selected.json present)" || no "pm-runtime selection missing from the view"
touch "$VIEW/$KEY/pm-runtime/.prepare.lock" 2>/dev/null && [ -w "$VIEW/$KEY/pm-runtime/.prepare.lock" ] \
  && ok "pm-runtime lock is writable in the task view" || no "pm-runtime lock is not writable"
[ -d "$VIEW/$KEY/environments" ] && [ -z "$(ls -A "$VIEW/$KEY/environments")" ] \
  && ok "the venv is NOT copied — environments stays an empty read-only mountpoint" || no "the venv was copied into the view"
ENV_PATH="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["packages"]["venv"]["environment"])' "$VIEW/$KEY/facts.json")"
case "$ENV_PATH" in
  "$GEN/environments/"*) ok "recorded venv path still resolves inside the install state dir (path semantics kept)" ;;
  *) no "recorded venv path is outside the state dir: $ENV_PATH" ;;
esac
[ -f "$GEN/environments/79024fc4/pyvenv.cfg" ] && ok "the selected venv keeps its pyvenv.cfg (read-only reuse)" || no "venv sanity file missing"

# === actual argv: writable install view + ro sub-binds + writable run state ========== #
ARGV="$(python3 - "$AEGL_ROOT/recovery/sandbox_spec.py" "$GEN" "$VIEW" "$KEY" "$ST" <<'PY'
import importlib.util, sys
m = importlib.util.module_from_spec(importlib.util.spec_from_file_location("ss", sys.argv[1]))
importlib.util.spec_from_file_location("ss", sys.argv[1]).loader.exec_module(m)
gen, view, key, st = sys.argv[2:6]
sb = [(st + "/home-sessions", "/home/zhong/.hermes/sessions"),
      (st + "/prof-logs", "/home/zhong/.hermes/profiles/android-stack/logs")]
a = m.build(bwrap="/usr/bin/bwrap", uid="994", gid="972", run="/run/t", wt="/tmp/wt", scr="/tmp/scr",
            runtime="/run/t/src/runtime", tools="/run/t/src/tools", entry="/run/t/src/entry",
            installs=gen, installs_view=view, install_key=key, state_binds=sb,
            guard_src="/run/t/src/guard", guard_dest="/home/zhong/g", contract_package="/pkg",
            hermes_args=["hermes"])["argv"]
print("\n".join(a))
PY
)"
ONE="$(printf '%s\n' "$ARGV" | tr '\n' ' ')"
grep -q -- "--bind $VIEW /home/zhong/.hermes/installs" <<<"$ONE" && ok "installs is a task-level WRITABLE bind at the expected path" || no "installs view bind missing"
grep -q -- '--overlay-src' <<<"$ONE" && no "the old read-only overlay is still used" || ok "no read-only overlay; a writable view is used"
grep -q -- "--ro-bind $GEN/environments /home/zhong/.hermes/installs/$KEY/environments" <<<"$ONE" \
  && ok "the venv is reused read-only by sub-bind" || no "missing read-only venv sub-bind"
for d in bootstrap pm-runtime inputs; do
  grep -q -- "--ro-bind $GEN/$d" <<<"$ONE" && no "$d is bound read-only (it holds mutable locks/state)" || ok "$d is writable (copied into the task view)"
done
grep -q -- "--bind $ST/home-sessions /home/zhong/.hermes/sessions" <<<"$ONE" && ok "sessions path is a task-level writable bind" || no "sessions bind missing"
grep -q -- "--bind $ST/prof-logs /home/zhong/.hermes/profiles/android-stack/logs" <<<"$ONE" && ok "profile logs path is a task-level writable bind" || no "profile logs bind missing"
grep -q -- '--tmpfs /home/zhong/.hermes/sessions' <<<"$ONE" && no "sessions is still an unwritable tmpfs" || ok "sessions is no longer a tmpfs"

# the writable mounts point at TASK dirs, never the real HOME
for bad in "/home/zhong/.hermes/installs $([ -d "$GEN" ] && echo GEN)"; do :; done
printf '%s\n' "$ONE" | grep -q -- "--bind $GEN " && no "the real generation dir is bound writable" || ok "the real generation dir is never bound writable"
printf '  NOTE: fixture only; aegl-ai host acceptance needs root and stays NOT_RUN\n'

rm -rf "$T"
echo "ENTRY_STATE_TESTS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
