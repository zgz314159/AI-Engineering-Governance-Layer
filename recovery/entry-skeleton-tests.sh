#!/usr/bin/env bash
# Focused check for THIS round only: the read-only /home/zhong skeleton must carry every
# mount target the ACTUAL argv references, with a matching type. It really executes the
# preparation and inspects the filesystem — it does not pass by grepping for commands.
set -u
AEGL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok(){ printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
no(){ printf '  FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

T="$(mktemp -d)"
HOST="$T/host"                       # stands in for the real /home/zhong sources
RUN="$T/run"; SK="$RUN/stage/home-zhong"
GREL="Projects/Google-Android-Agent-Development-Stack/orchestration/hermes/evaluation_adapter"
mkdir -p "$HOST/.hermes/hermes-agent" "$HOST/.hermes/tools" "$HOST/.hermes/installs" \
         "$HOST/.local/bin" "$HOST/$GREL" "$HOST/.hermes/newdir" "$RUN/stage" \
         "$SK/.hermes/profiles/android-stack" "$SK/.local/bin" "$SK/$GREL"
echo entry > "$HOST/.local/bin/hermes"
echo dummy > "$HOST/.hermes/.env"
: > "$RUN/stage/empty"                    # the launcher creates this stage file
printf 'model:\n  provider: custom\n' > "$SK/.hermes/config.yaml"
cp "$SK/.hermes/config.yaml" "$SK/.hermes/profiles/android-stack/config.yaml"
CFG_BEFORE="$(cat "$SK/.hermes/config.yaml")"
cp -a "$HOST" "$T/host.snapshot"     # to prove nothing outside the skeleton changes

SPEC="$T/spec.json"
python3 - "$AEGL_ROOT/recovery/sandbox_spec.py" "$SPEC" "$RUN" "$HOST" "$T" "$GREL" <<'PY'
import importlib.util, json, sys
spec_py, out, run, host, T, grel = sys.argv[1:7]
m = importlib.util.module_from_spec(importlib.util.spec_from_file_location("ss", spec_py))
importlib.util.spec_from_file_location("ss", spec_py).loader.exec_module(m)
spec = m.build(bwrap="/usr/bin/bwrap", uid="994", gid="972", run=run, wt=T, scr=T,
               runtime=host + "/.hermes/hermes-agent", tools=host + "/.hermes/tools",
               entry=host + "/.local/bin/hermes", installs=host + "/.hermes/installs",
               guard_src=host + "/" + grel, guard_dest="/home/zhong/" + grel,
               contract_package=T + "/contract", setpriv="/usr/bin/setpriv",
               info_fd="", hermes_args=["hermes"])
argv = spec["argv"]
# a brand-new mount the target list can only know from the ARGV (proves it is argv-driven)
i = argv.index("--chdir")
argv[i:i] = ["--ro-bind", host + "/.hermes/newdir", "/home/zhong/.hermes/newdir"]
json.dump(spec, open(out, "w"))
PY

python3 "$AEGL_ROOT/recovery/prepare_targets.py" "$SPEC" "$SK"; PRC=$?
[ "$PRC" = 0 ] && ok "prepare_targets ran against the real argv (rc=0)" || no "prepare_targets failed (rc=$PRC)"

isdir(){ [ -d "$1" ] && ok "$2" || no "$2 (missing or wrong type)"; }
isfile(){ [ -f "$1" ] && ok "$2" || no "$2 (missing or wrong type)"; }
isdir "$SK/.hermes/hermes-agent" "dir target .hermes/hermes-agent"
isdir "$SK/.hermes/tools" "dir target .hermes/tools"
isdir "$SK/.hermes/installs" "dir target .hermes/installs (tmp-overlay lower)"
isdir "$SK/.hermes/sessions" "dir target .hermes/sessions (tmpfs)"
isdir "$SK/$GREL" "dir target GUARD_DEST incl. the last level"
isfile "$SK/.local/bin/hermes" "file target .local/bin/hermes"
isfile "$SK/.hermes/.env" "file target .hermes/.env"
isdir "$SK/.hermes/profiles/android-stack" "existing profiles dir kept"
isdir "$SK/.hermes" "skeleton .hermes root exists"
isdir "$SK/.hermes/newdir" "argv-only mount dest was created (proves argv-driven)"

[ "$(cat "$SK/.hermes/config.yaml")" = "$CFG_BEFORE" ] && ok "existing config.yaml content preserved (not blanked)" || no "config.yaml was clobbered"

if diff -r "$T/host.snapshot" "$HOST" >/dev/null 2>&1; then ok "no change outside the skeleton (real HOME/project untouched)"; else no "something changed outside the skeleton"; fi

rm -rf "$T"
echo "SKELETON_TARGET_TESTS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
