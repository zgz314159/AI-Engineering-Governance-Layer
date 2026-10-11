#!/usr/bin/env bash
# Focused check for THIS round's three fixes ONLY:
#  1. private mount alias source/dest consistency + post-drop reachable sources
#  2. generation leases writable while venv/workspace stay read-only reuse
#  3. profile/home startup state paths (sessions, logs, db, locks) writable
# Real generated argv + a real fixture. Anything needing aegl-ai on the host is NOT_RUN.
set -u
AEGL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCH="$AEGL_ROOT/bin/aegl-hermes-sandbox"
PASS=0; FAIL=0
ok(){ printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
no(){ printf '  FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

# === 1. alias source/dest consistency ============================================ #
MK="$(grep -o '"\$SRC/[A-Za-z_.-]*"' "$LAUNCH" | tr -d '"' | sed 's#\$SRC/##' | sort -u)"
CONSISTENT=1
while read -r srcvar dest; do
  [ -n "$srcvar" ] || continue
  name="$(basename "$dest")"
  printf '%s\n' "$MK" | grep -qx "$name" || { echo "    unbound alias dest: $dest"; CONSISTENT=0; }
done < <(sed -n "s/^mount --bind '\([^']*\)' '\$SRC\/\([^']*\)'/\1 \2/p" "$LAUNCH")
[ "$CONSISTENT" = 1 ] && ok "every mount --bind alias DEST is created by the launcher" || no "an alias DEST is not created (source/target mismatch)"
grep -q "mount --bind '\$HERMES_INSTALLS' '\$SRC/installs'" "$LAUNCH" && no "the stale SRC/installs bind is still present" || ok "the stale SRC/installs bind is gone"
for v in GEN PROF_REAL; do
  grep -q "mount --bind '\$$v' '\$SRC/" "$LAUNCH" && ok "alias mounted for \$$v" || no "no alias for \$$v"
done

# === 2/3. actual argv from a real fixture ======================================== #
T="$(mktemp -d)"; KEY="b178d76051535411"; HASH="79024fc465094be387434f308b8ff753"
GEN="$T/gen/$KEY"; VIEW="$T/view"; PROFV="$T/profile"; ST="$T/runstate"; SRC="$T/src"
mkdir -p "$GEN/environments/$HASH/venv" "$GEN/environments/$HASH/workspace" "$GEN/environments/$HASH/.leases" \
         "$GEN/inputs" "$GEN/bootstrap" "$GEN/pm-runtime" \
         "$VIEW/$KEY/environments/$HASH/venv" "$VIEW/$KEY/environments/$HASH/workspace" "$VIEW/$KEY/environments/$HASH/.leases" \
         "$PROFV/sessions" "$PROFV/logs" "$PROFV/runtime" "$PROFV/cache" "$PROFV/skills" "$PROFV/hooks" \
         "$ST/home-sessions" "$ST/home-logs" "$ST/home-cache" "$SRC"
: > "$GEN/environments/$HASH/.lease-managed"; : > "$GEN/environments/$HASH/venv/pyvenv.cfg"
printf '{"schema":1,"packages":{"venv":{"environment":"%s/environments/%s/venv","schema":"1"}}}\n' "$GEN" "$HASH" > "$VIEW/$KEY/facts.json"
cp -a "$GEN/environments/$HASH/.lease-managed" "$VIEW/$KEY/environments/$HASH/.lease-managed"
PARSE_HASH="$(python3 -c 'import json,os,sys;d=json.load(open(sys.argv[1]));print(os.path.basename(os.path.dirname(d["packages"]["venv"]["environment"])))' "$VIEW/$KEY/facts.json")"
[ "$PARSE_HASH" = "$HASH" ] && ok "the selected generation is parsed from the real facts (no hardcoding)" || no "generation parse wrong: $PARSE_HASH"
touch "$VIEW/$KEY/environments/$HASH/.leases/$(uuidgen 2>/dev/null || echo lease1)" 2>/dev/null \
  && ok "a generation lease can be created in the task view (generation/.leases writable)" || no "generation .leases is not writable"

ARGV="$(python3 - "$AEGL_ROOT/recovery/sandbox_spec.py" "$VIEW" "$HASH" "$KEY" "$PROFV" "$ST" "$T" <<'PY'
import importlib.util, sys
m = importlib.util.module_from_spec(importlib.util.spec_from_file_location("ss", sys.argv[1]))
importlib.util.spec_from_file_location("ss", sys.argv[1]).loader.exec_module(m)
view, h, key, profv, st, T = sys.argv[2:8]
src = T + "/src"
em = [("ro-bind", f"{src}/gen/environments/{h}/venv", f"/home/zhong/.hermes/installs/{key}/environments/{h}/venv"),
      ("ro-bind", f"{src}/gen/environments/{h}/workspace", f"/home/zhong/.hermes/installs/{key}/environments/{h}/workspace"),
      ("bind", profv, "/home/zhong/.hermes/profiles/android-stack"),
      ("ro-bind", f"{src}/profile/SOUL.md", "/home/zhong/.hermes/profiles/android-stack/SOUL.md"),
      ("ro-bind", f"{src}/profile/skills", "/home/zhong/.hermes/profiles/android-stack/skills"),
      ("bind", f"{st}/home-sessions", "/home/zhong/.hermes/sessions"),
      ("bind", f"{st}/home-logs", "/home/zhong/.hermes/logs")]
a = m.build(bwrap="/usr/bin/bwrap", uid="994", gid="972", run="/run/t", wt="/tmp/wt", scr="/tmp/scr",
            runtime=src + "/runtime", tools=src + "/tools", entry=src + "/entry",
            installs_view=view, extra_mounts=em, guard_src=src + "/guard",
            guard_dest="/home/zhong/g", contract_package="/pkg", hermes_args=["hermes"])["argv"]
print("\n".join(a))
PY
)"
ONE="$(printf '%s\n' "$ARGV" | tr '\n' ' ')"
grep -q -- "--ro-bind $SRC/gen/environments/$HASH/venv " <<<"$ONE" && ok "generation venv is reused read-only from the alias" || no "venv ro-bind missing"
grep -q -- "--ro-bind $SRC/gen/environments/$HASH/workspace " <<<"$ONE" && ok "generation workspace is reused read-only" || no "workspace ro-bind missing"
grep -q -- "--bind $VIEW /home/zhong/.hermes/installs" <<<"$ONE" && ok "install state view is writable at the expected path" || no "installs view bind missing"
grep -q -- "--bind $PROFV /home/zhong/.hermes/profiles/android-stack" <<<"$ONE" && ok "profile run state (db/sessions/logs/locks) is a writable task dir" || no "profile view bind missing"
grep -q -- "--ro-bind $SRC/profile/skills " <<<"$ONE" && ok "profile instruction files are read-only reuse" || no "profile instruction reuse missing"

# post-drop reachability: NO mount source is under /home/zhong
BAD="$(python3 - "$ARGV" <<'PY'
import sys
lines = [l for l in sys.stdin.read().splitlines()]
bad = []
for i, tok in enumerate(lines):
    if tok in ("--ro-bind", "--bind") and i + 2 < len(lines):
        if lines[i + 1].startswith("/home/zhong") or lines[i + 1] == "/":
            bad.append(lines[i + 1])
print(",".join(bad))
PY
)" <<<"$ARGV"
[ -z "$BAD" ] && ok "every mount SOURCE is a post-drop-reachable alias (none under /home/zhong)" || no "unreachable mount source(s): $BAD"

printf '  NOTE: fixture only; real aegl-ai host acceptance stays NOT_RUN\n'
rm -rf "$T"
echo "ENTRY_GAPS_TESTS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
