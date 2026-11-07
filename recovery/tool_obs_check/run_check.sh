#!/usr/bin/env bash
# AEGL-TOOL-OBS-CHECK-r4 entry.
#
#   --self-test   ordinary-user checks only (hashes, Hermes version, manifest, fixture
#                 templates, trusted-view copy, HTTPS synthetic upstream, exact observer
#                 wiring, assertion negative cases). No root, no sandbox.
#   default       root-only isolated check (NOT run by this preparation round).
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1

PKG="$(cd "$(dirname "$0")/.." && pwd)"
MODE="full"
case "${1:-}" in
  --self-test) MODE="self-test" ;;
  "") : ;;
  *) echo "USAGE: run_smoke.sh [--self-test]" >&2; exit 2 ;;
esac

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
notrun() { printf 'NOT_RUN %s\n' "$1"; }
say() { printf '%s\n' "$*"; }

HERMES_RUNTIME="${HERMES_RUNTIME:-/home/zhong/.hermes/hermes-agent}"
HERMES_HOME="${HERMES_HOME_REAL:-/home/zhong/.hermes}"
HERMES_COMMIT="af90026aa09949579bd423d24def3d38f743cde0"
HERMES_VERSION_MARK="v0.21.5+6977.gaf90026"

declare -A WANT=(
  [bin/aegl-hermes-sandbox]=f3e556f079d14c6e4dd7173cd3a571b6e8a32527db12dc91aae44fbf75929479
  [bin/aegl-model-broker]=e7ca9db0fbd029cb3fb72b163e792fe9c62ca6b85c571569cf2ad9319917fba9
  [bin/model_broker.py]=7aa88b1831ca18fdbe9b14273321a90b352bb6026299b9bb9c26d4ca9b8ee59a
  [bin/tool_event_client.py]=f70630cacfdcb1afd5eff08ad20ada9737c91b097a42741a122a0fa651df83bf
  [bin/tool_observer_config.py]=424369561202ca48f122b8116fc6b2ebca8cbb1d108dbeb04674608b807591c3
)

# Packaged runtime dependencies that are not candidate-hash pins. Source recorded in
# DEPENDENCIES.md; the copy is unmodified and must never be resolved from the source
# repo, an installed tree or PYTHONPATH.
declare -A DEPS=(
  [bin/guard_capture.py]=4422f725fc2fb88ecff4de6baba81a519e4f450be5ad644948b29745d877be1a
)

VIEW_FILES=(
  aegl-hermes-sandbox aegl-model-broker model_broker.py guard_capture.py
  tool_event_client.py tool_observer_config.py guard_hook_client.py diag_events.py
  loopback_shim.py exec_spec.py sandbox_spec.py prepare_targets.py drop_verify.py
  model_config.py git_meta_mounts.sh guard/contract_guard.py
)

check_candidates() {
  local rel got
  for rel in "${!WANT[@]}"; do
    got="$(sha256sum "$PKG/$rel" 2>/dev/null | awk '{print $1}')"
    [ "$got" = "${WANT[$rel]}" ] && ok "candidate_hash $rel" || no "candidate_hash $rel (${got:-missing})"
  done
}

check_dependencies() {
  local rel got
  for rel in "${!DEPS[@]}"; do
    got="$(sha256sum "$PKG/$rel" 2>/dev/null | awk '{print $1}')"
    [ "$got" = "${DEPS[$rel]}" ] && ok "dependency_hash $rel" \
      || no "dependency_hash $rel (${got:-missing})"
  done
  # No implicit fallback: only model_broker + diag_events in an isolated cwd. The
  # guarded import must fail because guard_capture.py is deliberately absent.
  local tmp; tmp="$(mktemp -d /var/tmp/aegl-obs-dep.XXXXXX)" \
    || { no "dependency_no_fallback"; return; }
  if cp "$PKG/bin/model_broker.py" "$PKG/bin/diag_events.py" "$tmp/"; then
    if ( cd "$tmp" && PYTHONPATH= python3 -I -c \
         'import sys; sys.dont_write_bytecode=True; sys.path.insert(0, "."); import model_broker; model_broker._handle_guard(None, b"{}")' ) \
         >/dev/null 2>&1; then
      no "dependency_no_fallback"
    else
      ok "dependency_no_fallback"
    fi
  else
    no "dependency_no_fallback"
  fi
  rm -f "$tmp"/* "$tmp"/__pycache__/* 2>/dev/null || true
  rmdir "$tmp/__pycache__" "$tmp" 2>/dev/null || true
}

check_hermes() {
  local out commit
  out="$("$HERMES_RUNTIME/.hermes/bin/hermes" --version 2>&1)" || { no "hermes_version"; return; }
  case "$out" in *"$HERMES_VERSION_MARK"*) ok "hermes_version" ;; *) no "hermes_version ($out)" ;; esac
  commit="$(git -C "$HERMES_RUNTIME" rev-parse HEAD 2>/dev/null)"
  [ "$commit" = "$HERMES_COMMIT" ] && ok "hermes_commit" || no "hermes_commit ($commit)"
}

check_manifest() {
  [ -f "$PKG/MANIFEST.sha256" ] || { no "manifest_missing"; return; }
  ( cd "$PKG" && sha256sum -c --quiet MANIFEST.sha256 ) && ok "manifest_members" || no "manifest_members"
}

check_syntax() {
  bash -n "$PKG/bin/aegl-hermes-sandbox" && ok "launcher_syntax" || no "launcher_syntax"
  bash -n "$PKG/bin/run_smoke.sh" && ok "entry_syntax" || no "entry_syntax"
  python3 - "$PKG" <<'PY' && ok "check_python_syntax" || no "check_python_syntax"
import sys
base = sys.argv[1]
for name in ("fake_upstream.py", "assert_observation.py", "observer_dead_client.py",
             "assert_guard_capture.py", "guard_capture.py", "broker_guard_capture_test.py"):
    compile(open(base + "/bin/" + name, encoding="utf-8").read(), name, "exec")
PY
}

make_contract() { # <dir> <source-root>
  local dir="$1" root="$2"
  mkdir -p "$dir"
  python3 - "$dir" "$root" <<'PY'
import json, sys
d, root = sys.argv[1], sys.argv[2]
json.dump({"contract_id": "OBS-CLI-001", "allowed_paths": ["project"],
           "forbidden_paths": [], "read_first": []},
          open(d + "/implementation-contract.json", "w"))
json.dump({"project": "obs-check", "source_root": root, "read_first": [],
           "allowed_paths": ["project"], "forbidden_paths": []},
          open(d + "/project-context.json", "w"))
PY
}

check_contract_fixture() {
  local tmp; tmp="$(mktemp -d /var/tmp/aegl-obs-ct.XXXXXX)" || { no contract_fixture; return; }
  make_contract "$tmp/contract" "$tmp/task"
  python3 - "$tmp/contract" <<'PY' && ok contract_fixture || no contract_fixture
import json, sys
d = sys.argv[1]
c = json.load(open(d + "/implementation-contract.json"))
p = json.load(open(d + "/project-context.json"))
assert c["allowed_paths"] == ["project"] and p["source_root"]
PY
  rm -f "$tmp/contract/implementation-contract.json" "$tmp/contract/project-context.json"
  rmdir "$tmp/contract" "$tmp" 2>/dev/null || true
}

check_profile_fixture() {
  local tmp; tmp="$(mktemp -d /var/tmp/aegl-obs-pf.XXXXXX)" || { no profile_fixture; return; }
  cat > "$tmp/profile.yaml" <<EOF
hooks:
  pre_tool_call:
    - command: '/usr/bin/python3 $PKG/bin/guard/contract_guard.py'
      matcher: write_file|patch|terminal
      fail_closed: true
      timeout: 20
EOF
  local pre post guard
  guard="/usr/bin/python3 $PKG/bin/guard/contract_guard.py"
  pre="python3 /x/tool_event_client.py --socket /s --event pre_tool_call --timeout 0.5"
  post="python3 /x/tool_event_client.py --socket /s --event post_tool_call --timeout 0.5"
  if python3 "$PKG/bin/tool_observer_config.py" install "$tmp/profile.yaml" \
       --pre-command "$pre" --post-command "$post" >/dev/null \
     && python3 - "$tmp/allow.json" "$guard" "$pre" "$post" <<'PY'
import json, sys
json.dump({"approvals": [
    {"event": "pre_tool_call", "command": sys.argv[2]},
    {"event": "pre_tool_call", "command": sys.argv[3]},
    {"event": "post_tool_call", "command": sys.argv[4]}]}, open(sys.argv[1], "w"))
PY
     python3 "$PKG/bin/tool_observer_config.py" verify "$tmp/profile.yaml" "$tmp/allow.json" \
       --guard-command "$guard" --pre-command "$pre" \
       --post-command "$post" --diagnostics 1 >/dev/null; then
    ok profile_fixture
  else
    no profile_fixture
  fi
  rm -f "$tmp/profile.yaml" "$tmp/allow.json"; rmdir "$tmp" 2>/dev/null || true
}

check_model_config_fixture() {
  local tmp; tmp="$(mktemp -d /var/tmp/aegl-obs-mc.XXXXXX)" || { no model_config_fixture; return; }
  : > "$tmp/cred.env"
  cat > "$tmp/model.config" <<EOF
MODEL_API=openai-chat-completions
UPSTREAM=https://127.0.0.1:9443
MODEL_ID=obs-check
CREDENTIAL_SOURCE=$tmp/cred.env
CREDENTIAL_ENV=AEGL_OBS_DUMMY
AUTH_HEADER=Authorization
HERMES_ENTRY=$HERMES_RUNTIME/.hermes/bin/hermes
HERMES_RUNTIME=$HERMES_RUNTIME
HERMES_TOOLS=$HERMES_HOME/tools
HERMES_INSTALLS=$HERMES_HOME/installs
HERMES_HOME_REAL=$HERMES_HOME
HERMES_PROFILE_CONFIG=$tmp/profile.yaml
EOF
  python3 "$PKG/bin/model_config.py" --config "$tmp/model.config" validate >/dev/null \
    && ok model_config_fixture || no model_config_fixture
  rm -f "$tmp/model.config" "$tmp/cred.env"; rmdir "$tmp" 2>/dev/null || true
}

create_view() { # <src-pkg> <dst-view>
  local src="$1" dst="$2" rel
  case "$dst" in /root/*) return 1 ;; esac
  install -d -m 0755 "$dst" "$dst/bin" "$dst/bin/guard" || return 1
  for rel in "${VIEW_FILES[@]}"; do
    case "$rel" in aegl-model-broker) mode=0755 ;; *) mode=0644 ;; esac
    install -m "$mode" "$src/bin/$rel" "$dst/bin/$rel" || return 1
  done
  for rel in "${VIEW_FILES[@]}"; do
    [ "$(sha256sum "$src/bin/$rel" | awk '{print $1}')" = "$(sha256sum "$dst/bin/$rel" | awk '{print $1}')" ] \
      || return 1
  done
  return 0
}

create_dead_view() { # <view> <deadview> <dead-client> — only tool_event_client.py differs
  local view="$1" dead="$2" client="$3" rel mode
  [ ! -e "$dead" ] && [ ! -L "$dead" ] || return 1
  install -d -m 0755 "$dead" "$dead/bin" "$dead/bin/guard" || return 1
  for rel in "${VIEW_FILES[@]}"; do
    case "$rel" in aegl-model-broker) mode=0755 ;; *) mode=0644 ;; esac
    install -m "$mode" "$view/bin/$rel" "$dead/bin/$rel" || return 1
  done
  install -m 0644 "$client" "$dead/bin/tool_event_client.py" || return 1
  for rel in "${VIEW_FILES[@]}"; do
    [ -f "$dead/bin/$rel" ] || return 1
    local got want
    got="$(sha256sum "$dead/bin/$rel" | awk '{print $1}')"
    want="$(sha256sum "$view/bin/$rel" | awk '{print $1}')"
    if [ "$rel" = "tool_event_client.py" ]; then
      [ "$got" != "$want" ] || return 1
    else
      [ "$got" = "$want" ] || return 1
    fi
  done
  return 0
}

clean_worktree_product() { # <repo> <worktree> <alive> <expected-owner>
  local repo="$1" wt="$2" alive="$3" owner="$4" st rc=0
  [ -f "$alive" ] && [ ! -L "$alive" ] || return 1
  [ "$(cat "$alive")" = "alive" ] || return 1
  [ "$(stat -c '%U' "$alive")" = "$owner" ] || return 1
  rm -f -- "$alive" || return 1
  # Root queries an aegl-ai-owned worktree: trust exactly this path at command level,
  # never a global/wildcard safe.directory.
  st="$(git -c safe.directory="$wt" -C "$wt" status --porcelain 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || return 1
  [ -z "$st" ] || return 1
  git -c safe.directory="$wt" -C "$repo" worktree remove "$wt"
}

check_trusted_view() {
  local tmp; tmp="$(mktemp -d /var/tmp/aegl-obs-view.XXXXXX)" || { no trusted_view; return; }
  if create_view "$PKG" "$tmp/view" && [ ! -L "$tmp/view" ]; then
    ok trusted_view
  else
    no trusted_view
  fi
  local rel
  for rel in "${VIEW_FILES[@]}"; do rm -f "$tmp/view/bin/$rel"; done
  rmdir "$tmp/view/bin/guard" "$tmp/view/bin" "$tmp/view" "$tmp" 2>/dev/null || true
}

check_dead_view() {
  local tmp; tmp="$(mktemp -d /var/tmp/aegl-obs-dv.XXXXXX)" || { no dead_view; return; }
  if create_view "$PKG" "$tmp/view" \
     && create_dead_view "$tmp/view" "$tmp/deadview" "$PKG/bin/observer_dead_client.py"; then
    local rel bad=0
    for rel in "${VIEW_FILES[@]}"; do
      [ -f "$tmp/deadview/bin/$rel" ] || bad=1
    done
    for rel in "${VIEW_FILES[@]}"; do
      [ "$rel" = "tool_event_client.py" ] && continue
      [ "$(sha256sum "$tmp/deadview/bin/$rel" | awk '{print $1}')" = "$(sha256sum "$tmp/view/bin/$rel" | awk '{print $1}')" ] || bad=1
    done
    [ "$(sha256sum "$tmp/deadview/bin/tool_event_client.py" | awk '{print $1}')" != "$(sha256sum "$tmp/view/bin/tool_event_client.py" | awk '{print $1}')" ] || bad=1
    [ "$(sha256sum "$tmp/deadview/bin/tool_event_client.py" | awk '{print $1}')" = "$(sha256sum "$PKG/bin/observer_dead_client.py" | awk '{print $1}')" ] || bad=1
    [ "$bad" -eq 0 ] && ok dead_view || no dead_view
  else
    no dead_view
  fi
  local rel
  for rel in "${VIEW_FILES[@]}"; do rm -f "$tmp/deadview/bin/$rel" "$tmp/view/bin/$rel"; done
  rmdir "$tmp/deadview/bin/guard" "$tmp/deadview/bin" "$tmp/deadview" \
        "$tmp/view/bin/guard" "$tmp/view/bin" "$tmp/view" "$tmp" 2>/dev/null || true
}

check_guard_capture() {
  local tmp; tmp="$(mktemp -d /var/tmp/aegl-obs-gc.XXXXXX)" || { no guard_capture; return; }
  if ! install -d "$tmp/ev-block" "$tmp/ev-allow" "$tmp/ev-mismatch" \
       "$tmp/work" "$tmp/diag"; then
    no guard_capture; rmdir "$tmp" 2>/dev/null || true; return
  fi
  cat > "$tmp/guard_block.py" <<'PY'
import json, sys
sys.stdout.write(json.dumps({"action": "block", "message": "fixture"}))
sys.exit(2)
PY
  cat > "$tmp/guard_allow.py" <<'PY'
import json, sys
sys.stdout.write(json.dumps({"action": "allow", "message": "fixture"}))
sys.exit(0)
PY
  local ai_uid ai_gid
  ai_uid="$(id -u aegl-ai 2>/dev/null || echo 65534)"
  ai_gid="$(id -g aegl-ai 2>/dev/null || echo 65534)"
  local base=(--package-bin "$PKG/bin" --task BRIDGE-DIAG-003 --call-id test-block
              --target-basename guard-blocked --workdir "$tmp/work" --diag "$tmp/diag"
              --ai-uid "$ai_uid" --ai-gid "$ai_gid")
  local good=0 bad=0 rc=0
  PYTHONPATH= python3 -I "$PKG/bin/broker_guard_capture_test.py" "${base[@]}" \
    --guard "$tmp/guard_block.py" --evidence "$tmp/ev-block" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ] \
     && python3 "$PKG/bin/assert_guard_capture.py" --capture "$tmp/ev-block/guard-capture.jsonl" \
          --call-id test-block --target-basename guard-blocked --task BRIDGE-DIAG-003 >/dev/null; then
    good=1
  fi
  # real ALLOW write path: the persisted record must fail the block assertion
  rc=0; PYTHONPATH= python3 -I "$PKG/bin/broker_guard_capture_test.py" "${base[@]}" \
    --guard "$tmp/guard_allow.py" --evidence "$tmp/ev-allow" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    python3 "$PKG/bin/assert_guard_capture.py" --capture "$tmp/ev-allow/guard-capture.jsonl" \
      --call-id test-block --target-basename guard-blocked --task BRIDGE-DIAG-003 >/dev/null 2>&1 \
      && bad=$((bad + 1))
  else
    bad=$((bad + 1))
  fi
  # real argument-mismatch write path: incomplete correlation must fail
  rc=0; PYTHONPATH= python3 -I "$PKG/bin/broker_guard_capture_test.py" "${base[@]}" \
    --guard "$tmp/guard_block.py" --evidence "$tmp/ev-mismatch" --mismatch >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    python3 "$PKG/bin/assert_guard_capture.py" --capture "$tmp/ev-mismatch/guard-capture.jsonl" \
      --call-id test-block --target-basename guard-blocked --task BRIDGE-DIAG-003 >/dev/null 2>&1 \
      && bad=$((bad + 1))
  else
    bad=$((bad + 1))
  fi
  # unrelated request id against the real block record
  python3 "$PKG/bin/assert_guard_capture.py" --capture "$tmp/ev-block/guard-capture.jsonl" \
    --call-id other --target-basename guard-blocked --task BRIDGE-DIAG-003 >/dev/null 2>&1 \
    && bad=$((bad + 1))
  # missing record
  : > "$tmp/empty"
  python3 "$PKG/bin/assert_guard_capture.py" --capture "$tmp/empty" \
    --call-id test-block --target-basename guard-blocked --task BRIDGE-DIAG-003 >/dev/null 2>&1 \
    && bad=$((bad + 1))
  # incomplete: remove the persisted terminal marker from a copy of the real record
  cp "$tmp/ev-block/guard-capture.jsonl" "$tmp/norec"
  python3 - "$tmp/norec" <<'PY'
import json, sys
path = sys.argv[1]
rows = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
for row in rows:
    row.pop("_recorded", None)
with open(path, "w", encoding="utf-8") as fh:
    for row in rows:
        fh.write(json.dumps(row) + "\n")
PY
  python3 "$PKG/bin/assert_guard_capture.py" --capture "$tmp/norec" \
    --call-id test-block --target-basename guard-blocked --task BRIDGE-DIAG-003 >/dev/null 2>&1 \
    && bad=$((bad + 1))
  [ "$good" -eq 1 ] && [ "$bad" -eq 0 ] && ok guard_capture || no guard_capture
  rm -f "$tmp"/*.py "$tmp"/ev-block/* "$tmp"/ev-allow/* "$tmp"/ev-mismatch/* \
    "$tmp"/diag/* "$tmp"/norec "$tmp"/empty 2>/dev/null || true
  rmdir "$tmp/ev-block" "$tmp/ev-allow" "$tmp/ev-mismatch" "$tmp/work" "$tmp/diag" \
    "$tmp" 2>/dev/null || true
}

check_worktree_product_cleanup() {
  local tmp; tmp="$(mktemp -d /var/tmp/aegl-obs-wt.XXXXXX)" || { no worktree_product_cleanup; return; }
  local flag=0
  if git init -q "$tmp/repo" \
     && git -C "$tmp/repo" -c user.name=t -c user.email=t@x commit -q --allow-empty -m base \
     && git -C "$tmp/repo" worktree add -q "$tmp/wt" -b wt; then
    printf 'alive' > "$tmp/wt/observer-alive"
    printf 'unknown' > "$tmp/wt/unknown-file"
    local rc1=0
    clean_worktree_product "$tmp/repo" "$tmp/wt" "$tmp/wt/observer-alive" "$(id -un)" >/dev/null 2>&1 || rc1=$?
    local kept=0; [ -d "$tmp/wt" ] && kept=1
    local neg=0; [ "$rc1" -ne 0 ] && [ "$kept" -eq 1 ] && neg=1
    printf 'alive' > "$tmp/wt/observer-alive"
    rm -f "$tmp/wt/unknown-file"
    local rc2=0
    clean_worktree_product "$tmp/repo" "$tmp/wt" "$tmp/wt/observer-alive" "$(id -un)" >/dev/null 2>&1 || rc2=$?
    local gone=0; [ ! -e "$tmp/wt" ] && gone=1
    [ "$neg" -eq 1 ] && [ "$rc2" -eq 0 ] && [ "$gone" -eq 1 ] && flag=1
  fi
  [ "$flag" -eq 1 ] && ok worktree_product_cleanup || no worktree_product_cleanup
  if [ -d "$tmp/wt" ]; then git -C "$tmp/repo" worktree remove "$tmp/wt" 2>/dev/null || true; fi
  if [ -d "$tmp/repo" ]; then
    find "$tmp/repo" -type f 2>/dev/null | while IFS= read -r p; do rm -f "$p"; done
    find "$tmp/repo" -depth -type d 2>/dev/null | while IFS= read -r p; do rmdir "$p" 2>/dev/null || true; done
  fi
  rmdir "$tmp" 2>/dev/null || true
}

make_valid_sink() { # <path>
  python3 - "$1" <<'PY'
import json, sys
p = sys.argv[1]
rows = [
 {"phase": "model_response", "seq": 10, "arg": "flags=text,tool_call calls=3 callseq=1,2,3 finish=TOOL_CALLS"},
 {"phase": "model_tool_request", "seq": 1, "arg": "resp=10 tool=terminal"},
 {"phase": "model_tool_request", "seq": 2, "arg": "resp=10 tool=terminal"},
 {"phase": "model_tool_request", "seq": 3, "arg": "resp=10 tool=terminal"},
 {"phase": "tool_pre_observe", "seq": 1, "arg": "src=hook trust=diagnostic when=pre corr=1 tool=terminal status=OK err=UNKNOWN"},
 {"phase": "tool_post_observe", "seq": 1, "arg": "src=hook trust=diagnostic when=post corr=1 tool=terminal status=OK err=UNKNOWN duration_ms=1 exit=0"},
 {"phase": "tool_pre_observe", "seq": 2, "arg": "src=hook trust=diagnostic when=pre corr=1 tool=terminal status=OK err=UNKNOWN"},
 {"phase": "tool_post_observe", "seq": 2, "arg": "src=hook trust=diagnostic when=post corr=1 tool=terminal status=ERROR err=tool_error duration_ms=2 exit=7"},
 {"phase": "tool_pre_observe", "seq": 3, "arg": "src=hook trust=diagnostic when=pre corr=1 tool=terminal status=OK err=UNKNOWN"},
 {"phase": "tool_post_observe", "seq": 3, "arg": "src=hook trust=diagnostic when=post corr=1 tool=terminal status=BLOCKED err=UNKNOWN duration_ms=UNKNOWN exit=UNKNOWN"},
]
with open(p, "w", encoding="utf-8") as fh:
    for row in rows:
        fh.write(json.dumps(row) + "\n")
PY
}

mutate_sink() { # <src> <dst> <python-mutation>
  cp "$1" "$2"
  python3 - "$2" "$3" <<'PY'
import json, sys
path, mutation = sys.argv[1], sys.argv[2]
rows = [json.loads(l) for l in open(path, encoding="utf-8") if l.strip()]
exec(mutation)
with open(path, "w", encoding="utf-8") as fh:
    for row in rows:
        fh.write(json.dumps(row) + "\n")
PY
}

check_assert_negatives() {
  local tmp; tmp="$(mktemp -d /var/tmp/aegl-obs-as.XXXXXX)" || { no assert_negatives; return; }
  make_valid_sink "$tmp/valid"
  : > "$tmp/forbidden"
  local allow_rc=0
  python3 "$PKG/bin/assert_observation.py" --events "$tmp/valid" --forbidden "$tmp/none" >/dev/null || allow_rc=$?
  local bad=0
  mutate_sink "$tmp/valid" "$tmp/pre_seq1" "rows[:] = [({**r, 'seq': 1}) if r.get('phase') == 'tool_pre_observe' else r for r in rows]"
  mutate_sink "$tmp/valid" "$tmp/exit70" "rows[:] = [({**r, 'arg': r['arg'].replace('exit=7', 'exit=70')}) if r.get('phase') == 'tool_post_observe' and r.get('seq') == 2 else r for r in rows]"
  mutate_sink "$tmp/valid" "$tmp/missing_post" "rows[:] = [r for i, r in enumerate(rows) if not (r.get('phase') == 'tool_post_observe' and r.get('seq') == 2)]"
  mutate_sink "$tmp/valid" "$tmp/duplicate_post" "rows[:] = rows + [next(r for r in rows if r.get('phase') == 'tool_post_observe' and r.get('seq') == 1)]"
  mutate_sink "$tmp/valid" "$tmp/extra_pre" "rows[:] = rows + [{'phase': 'tool_pre_observe', 'seq': 4, 'arg': 'src=hook trust=diagnostic when=pre corr=1 tool=terminal status=OK err=UNKNOWN'}]"
  mutate_sink "$tmp/valid" "$tmp/post_before_pre" "rows[:] = [r for r in rows if r.get('phase') == 'model_response'] + [r for r in rows if r.get('phase') == 'model_tool_request'] + [r for r in rows if r.get('phase') == 'tool_post_observe'] + [r for r in rows if r.get('phase') == 'tool_pre_observe']"
  local name
  for name in pre_seq1 exit70 missing_post duplicate_post extra_pre post_before_pre; do
    python3 "$PKG/bin/assert_observation.py" --events "$tmp/$name" --forbidden "$tmp/none" >/dev/null 2>&1 \
      && bad=$((bad + 1))
  done
  [ "$allow_rc" -eq 0 ] && [ "$bad" -eq 0 ] && ok assert_negatives || no assert_negatives
  rm -f "$tmp"/*; rmdir "$tmp" 2>/dev/null || true
}

check_fake_upstream() {
  local tmp; tmp="$(mktemp -d /var/tmp/aegl-obs-tls.XXXXXX)" || { no fake_upstream_https; return; }
  if ! openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
       -days 1 -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" \
       -addext "basicConstraints=critical,CA:TRUE" >/dev/null 2>&1; then
    no fake_upstream_https; rm -f "$tmp"/*; rmdir "$tmp" 2>/dev/null || true; return
  fi
  python3 "$PKG/bin/fake_upstream.py" --cert "$tmp/cert.pem" --key "$tmp/key.pem" \
    --port-file "$tmp/port" --block-path "$tmp/blocked" >/dev/null 2>&1 &
  local pid=$! i port
  for i in $(seq 1 100); do [ -s "$tmp/port" ] && break; sleep 0.05; done
  port="$(cat "$tmp/port" 2>/dev/null || true)"
  if [ -z "$port" ]; then
    no fake_upstream_https; kill "$pid" 2>/dev/null
  else
    if SSL_CERT_FILE="$tmp/cert.pem" python3 - "$port" <<'PY'
import http.client, json, sys, ssl
ctx = ssl.create_default_context()
conn = http.client.HTTPSConnection("127.0.0.1", int(sys.argv[1]), context=ctx, timeout=5)
conn.request("POST", "/v1/chat/completions", body=b'{"model":"obs-check"}',
             headers={"Content-Type": "application/json"})
resp = conn.getresponse()
data = json.loads(resp.read())
conn.close()
call = data["choices"][0]["message"]["tool_calls"][0]
assert call["id"] == "obs-ok" and call["function"]["name"] == "terminal"
PY
    then ok fake_upstream_https; else no fake_upstream_https; fi
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
  fi
  rm -f "$tmp"/*; rmdir "$tmp" 2>/dev/null || true
}

self_test() {
  say "SELF_TEST begin pkg=$PKG"
  check_candidates
  check_dependencies
  check_hermes
  check_manifest
  check_syntax
  check_contract_fixture
  check_profile_fixture
  check_model_config_fixture
  check_trusted_view
  check_dead_view
  check_guard_capture
  check_worktree_product_cleanup
  check_assert_negatives
  check_fake_upstream
  notrun root_bwrap_check_mode_sink_absence
  notrun root_bwrap_real_tool_executor
  notrun root_bwrap_guard_block_no_execution
  notrun root_bwrap_observer_failure_independence
  notrun host_isolation
  say "SELF_TEST pass=$PASS fail=$FAIL"
  [ "$FAIL" -eq 0 ]
}

# --- root-only isolated check (prepared; NOT run this round) --------------------------
ROOT_FAIL=0
root_no() { ROOT_FAIL=$((ROOT_FAIL + 1)); printf 'FAIL %s %s\n' "$1" "${2:-}"; }
root_ok() { printf 'PASS %s\n' "$1"; }
UP_PIDS=()

snapshot_host() { # <out>
  local out="$1" p
  : > "$out"
  for p in /var/lib/aegl-model/registry.json \
           /home/zhong/.local/state/google-android-agent-stack/bridge/state.json; do
    if [ -r "$p" ]; then
      printf 'FILE %s %s\n' "$p" "$(sha256sum "$p" | awk '{print $1}')" >> "$out"
    else
      printf 'UNREADABLE %s\n' "$p" >> "$out"
    fi
  done
  for p in /var/tmp/aegl-diag/BRIDGE-DIAG-003 /run/aegl-model/BRIDGE-DIAG-003; do
    if [ -e "$p" ]; then
      printf 'PRESENT %s %s\n' "$p" "$(stat -c '%F %s %Y' "$p")" >> "$out"
    else
      printf 'ABSENT %s\n' "$p" >> "$out"
    fi
  done
}

root_check() {
  [ "$(id -u)" -eq 0 ] || { echo "NOT_RUN root_required"; exit 1; }
  local tool
  for tool in unshare bwrap openssl setpriv git install; do
    command -v "$tool" >/dev/null || { echo "OBS_CHECK=FAIL phase=missing_tool_$tool"; exit 1; }
  done
  id -u aegl-ai >/dev/null 2>&1 || { echo "OBS_CHECK=FAIL phase=missing_aegl_ai"; exit 1; }
  set -Eeuo pipefail

  check_candidates
  check_dependencies
  check_hermes
  check_manifest
  check_syntax
  check_contract_fixture
  check_profile_fixture
  check_model_config_fixture
  [ "$FAIL" -eq 0 ] || { echo "OBS_CHECK=FAIL phase=prechecks"; exit 1; }

  local fixture
  fixture="$(mktemp -d /var/tmp/AEGL-TOOL-OBS-CHECK.r4.XXXXXX)" \
    || { echo "OBS_CHECK=FAIL phase=fixture_mktemp"; exit 1; }
  [ -d "$fixture" ] && [ ! -L "$fixture" ] || { echo "OBS_CHECK=FAIL phase=fixture_type"; exit 1; }
  chmod 0755 "$fixture"
  local rec="$fixture/.created"
  : > "$rec"
  record() { printf '%s\n' "$1" >> "$rec"; }
  trap 'rc=$?; for pid in "${UP_PIDS[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done; if [ "$rc" -ne 0 ] || [ "$ROOT_FAIL" -ne 0 ]; then echo "SCENE_KEPT=$fixture"; fi' EXIT

  install -d -m 0755 "$fixture/task" "$fixture/task/project" "$fixture/task/scratch" \
    "$fixture/repo" "$fixture/contract" "$fixture/diag-root" "$fixture/diag-root-observer" \
    "$fixture/run-root" "$fixture/run-root-observer" "$fixture/tls" \
    "$fixture/view" || { echo "OBS_CHECK=FAIL phase=fixture_dirs"; exit 1; }
  for d in "$fixture" "$fixture/task" "$fixture/task/project" "$fixture/task/scratch" \
           "$fixture/repo" "$fixture/contract" "$fixture/diag-root" \
           "$fixture/diag-root-observer" "$fixture/run-root" "$fixture/run-root-observer" \
           "$fixture/tls" "$fixture/view"; do record "$d"; done

  create_view "$PKG" "$fixture/view" || { echo "OBS_CHECK=FAIL phase=trusted_view"; exit 1; }
  find "$fixture/view" -type f | while IFS= read -r p; do record "$p"; done
  find "$fixture/view" -type d | while IFS= read -r p; do record "$p"; done
  create_dead_view "$fixture/view" "$fixture/deadview" "$PKG/bin/observer_dead_client.py" \
    || { echo "OBS_CHECK=FAIL phase=dead_view"; exit 1; }
  chown -R root:root "$fixture/view" "$fixture/deadview"
  chmod 0755 "$fixture/view/bin/aegl-model-broker" "$fixture/deadview/bin/aegl-model-broker"
  find "$fixture/deadview" -type f | while IFS= read -r p; do record "$p"; done
  find "$fixture/deadview" -type d | while IFS= read -r p; do record "$p"; done
  chown aegl-ai:aegl-ai "$fixture/task/project" "$fixture/task/scratch"
  chmod 0750 "$fixture/task/scratch"

  snapshot_host "$fixture/host.before"
  record "$fixture/host.before"

  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$fixture/tls/key.pem" \
    -out "$fixture/tls/cert.pem" -days 1 -subj "/CN=127.0.0.1" \
    -addext "subjectAltName=IP:127.0.0.1" \
    -addext "basicConstraints=critical,CA:TRUE" >/dev/null 2>&1 \
    || { echo "OBS_CHECK=FAIL phase=tls"; exit 1; }
  chmod 0600 "$fixture/tls/key.pem"; chmod 0644 "$fixture/tls/cert.pem"
  record "$fixture/tls/key.pem"; record "$fixture/tls/cert.pem"

  python3 "$PKG/bin/fake_upstream.py" --cert "$fixture/tls/cert.pem" \
    --key "$fixture/tls/key.pem" --port-file "$fixture/port-main" \
    --block-path "$fixture/task/scratch/guard-blocked" >/dev/null 2>&1 &
  UP_PIDS+=("$!")
  python3 "$PKG/bin/fake_upstream.py" --cert "$fixture/tls/cert.pem" \
    --key "$fixture/tls/key.pem" --port-file "$fixture/port-observer" \
    --mode observer-failure --alive-path "$fixture/task/project/observer-alive" \
    --block-path "$fixture/task/scratch/guard-blocked-observer" >/dev/null 2>&1 &
  UP_PIDS+=("$!")
  local i
  for i in $(seq 1 100); do
    [ -s "$fixture/port-main" ] && [ -s "$fixture/port-observer" ] && break
    sleep 0.05
  done
  local port_main port_observer
  port_main="$(cat "$fixture/port-main" 2>/dev/null || true)"
  port_observer="$(cat "$fixture/port-observer" 2>/dev/null || true)"
  [ -n "$port_main" ] && [ -n "$port_observer" ] || { echo "OBS_CHECK=FAIL phase=upstream"; exit 1; }
  record "$fixture/port-main"; record "$fixture/port-observer"

  make_contract "$fixture/contract" "$fixture/task"
  record "$fixture/contract/implementation-contract.json"
  record "$fixture/contract/project-context.json"
  python3 - "$fixture" <<'PY'
import json, sys
f = sys.argv[1]
json.dump({"BRIDGE-DIAG-003": {
    "worktree": f + "/task/project", "scratch": f + "/task/scratch",
    "project": f + "/repo", "contract_package": f + "/contract"}},
    open(f + "/registry.json", "w"))
PY
  chmod 0600 "$fixture/registry.json"; record "$fixture/registry.json"

  cat > "$fixture/profile.yaml" <<EOF
hooks:
  pre_tool_call:
    - command: '/usr/bin/python3 $fixture/view/bin/guard/contract_guard.py'
      matcher: write_file|patch|terminal
      fail_closed: true
      timeout: 20
EOF
  chmod 0644 "$fixture/profile.yaml"; record "$fixture/profile.yaml"
  printf 'AEGL_OBS_DUMMY=dummy\n' > "$fixture/cred.env"
  chmod 0600 "$fixture/cred.env"; record "$fixture/cred.env"
  printf 'Run the fixed local observation checks.\n' > "$fixture/prompt.txt"
  chmod 0644 "$fixture/prompt.txt"; record "$fixture/prompt.txt"

  write_model_config() { # <path> <port>
    cat > "$1" <<EOF
MODEL_API=openai-chat-completions
UPSTREAM=https://127.0.0.1:$2
MODEL_ID=obs-check
CREDENTIAL_SOURCE=$fixture/cred.env
CREDENTIAL_ENV=AEGL_OBS_DUMMY
AUTH_HEADER=Authorization
HERMES_ENTRY=$HERMES_RUNTIME/.hermes/bin/hermes
HERMES_RUNTIME=$HERMES_RUNTIME
HERMES_TOOLS=$HERMES_HOME/tools
HERMES_INSTALLS=$HERMES_HOME/installs
HERMES_HOME_REAL=$HERMES_HOME
HERMES_PROFILE_CONFIG=$fixture/profile.yaml
EOF
    chmod 0600 "$1"
  }
  write_model_config "$fixture/model.config" "$port_main"; record "$fixture/model.config"
  write_model_config "$fixture/model.observer.config" "$port_observer"
  record "$fixture/model.observer.config"

  git init -q "$fixture/repo" || { echo "OBS_CHECK=FAIL phase=git_init"; exit 1; }
  printf 'plan\n' > "$fixture/repo/PLAN.md"
  git -C "$fixture/repo" add PLAN.md || { echo "OBS_CHECK=FAIL phase=git_add"; exit 1; }
  git -C "$fixture/repo" -c user.name=obs -c user.email=obs@local commit -qm base \
    || { echo "OBS_CHECK=FAIL phase=git_commit"; exit 1; }
  git -C "$fixture/repo" worktree add -q "$fixture/task/project" -b obs-check \
    || { echo "OBS_CHECK=FAIL phase=git_worktree"; exit 1; }
  chown -R aegl-ai:aegl-ai "$fixture/task/project"
  find "$fixture/repo" -type f -not -path "$fixture/repo/.git/*" | while IFS= read -r p; do record "$p"; done
  find "$fixture/repo" -type f -path "$fixture/repo/.git/*" | while IFS= read -r p; do record "$p"; done
  find "$fixture/repo" -type d | while IFS= read -r p; do record "$p"; done

  run_ns() { # <diag-root> <run-root> <libdir> <config> <cmd...>
    local diag="$1" run="$2" lib="$3" cfg="$4"; shift 4
    unshare --mount --propagation private -- bash -c '
      set -e
      mount --bind "$1" /var/tmp/aegl-diag
      mount --bind "$2" /run/aegl-model
      shift 2
      exec "$@"
    ' _ "$diag" "$run" env AEGL_MODEL_CONFIG="$cfg" \
      AEGL_MODEL_TASK_REGISTRY="$fixture/registry.json" \
      AEGL_MODEL_LIBDIR="$lib" SSL_CERT_FILE="$fixture/tls/cert.pem" "$@"
  }

  if ! run_ns "$fixture/diag-root" "$fixture/run-root" "$fixture/view/bin" \
       "$fixture/model.config" true >/dev/null 2>&1; then
    echo "OBS_CHECK=FAIL phase=namespace_mount"; exit 1
  fi

  local out rc=0
  out="$(run_ns "$fixture/diag-root" "$fixture/run-root" "$fixture/view/bin" \
         "$fixture/model.config" "$PKG/bin/aegl-hermes-sandbox" --task BRIDGE-DIAG-003 \
         --check "printf probe > $fixture/task/scratch/check-write-probe; printf OBS_CHECK_OK" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'SANDBOX_CHECK_RC=0' \
     && printf '%s' "$out" | grep -q 'OBS_CHECK_OK' \
     && printf '%s' "$out" | grep -q 'allowlist=1' \
     && [ -f "$fixture/task/scratch/check-write-probe" ] \
     && [ "$(stat -c '%U' "$fixture/task/scratch/check-write-probe")" = aegl-ai ] \
     && [ ! -e "$fixture/diag-root/BRIDGE-DIAG-003" ]; then
    root_ok check_mode_guard_only_no_sink
    root_ok sandbox_identity_can_write_scratch
  else
    root_no check_mode_guard_only_no_sink "rc=$rc"
    root_no sandbox_identity_can_write_scratch
  fi
  rm -f "$fixture/task/scratch/check-write-probe" \
    || { echo "OBS_CHECK=FAIL phase=probe_cleanup"; exit 1; }

  rc=0
  out="$(run_ns "$fixture/diag-root" "$fixture/run-root" "$fixture/view/bin" \
         "$fixture/model.config" "$PKG/bin/aegl-hermes-sandbox" --task BRIDGE-DIAG-003 -- \
         hermes -p android-stack chat --oneshot --query-file "$fixture/prompt.txt" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] && root_ok real_tool_executor_exit || root_no real_tool_executor_exit "rc=$rc"
  local sink_main="$fixture/diag-root/BRIDGE-DIAG-003/events.jsonl"
  if [ -f "$sink_main" ] \
     && python3 "$PKG/bin/assert_observation.py" --events "$sink_main" \
          --forbidden "$fixture/task/scratch/guard-blocked" --fixture "$fixture" >/dev/null; then
    root_ok real_pre_post_sink_and_guard_block
  else
    root_no real_pre_post_sink_and_guard_block
  fi
  [ ! -e "$fixture/run-root/BRIDGE-DIAG-003" ] && root_ok run_dir_removed \
    || root_no run_dir_removed
  [ -f "$sink_main" ] && root_ok sink_survives_run_dir_removal || root_no sink_survives_run_dir_removal
  local capture_main="$fixture/diag-root/BRIDGE-DIAG-003/guard-capture.jsonl"
  if python3 "$PKG/bin/assert_guard_capture.py" --capture "$capture_main" \
       --call-id obs-block --target-basename guard-blocked --task BRIDGE-DIAG-003 >/dev/null; then
    root_ok guard_capture_main_block
  else
    root_no guard_capture_main_block
  fi

  record "$fixture/task/project/observer-alive"
  rc=0
  out="$(run_ns "$fixture/diag-root-observer" "$fixture/run-root-observer" "$fixture/deadview/bin" \
         "$fixture/model.observer.config" "$PKG/bin/aegl-hermes-sandbox" --task BRIDGE-DIAG-003 -- \
         hermes -p android-stack chat --oneshot --query-file "$fixture/prompt.txt" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] && root_ok observer_failure_run_exit || root_no observer_failure_run_exit "rc=$rc"
  if [ -f "$fixture/task/project/observer-alive" ] \
     && [ "$(cat "$fixture/task/project/observer-alive")" = "alive" ] \
     && [ "$(stat -c '%U' "$fixture/task/project/observer-alive")" = aegl-ai ] \
     && [ ! -e "$fixture/task/scratch/guard-blocked-observer" ]; then
    root_ok observer_failure_allowed_executed_blocked_not
  else
    root_no observer_failure_allowed_executed_blocked_not
  fi
  local sink_obs="$fixture/diag-root-observer/BRIDGE-DIAG-003/events.jsonl"
  if [ -f "$sink_obs" ] \
     && ! grep -q '"phase": "tool_pre_observe"' "$sink_obs" \
     && ! grep -q '"phase": "tool_post_observe"' "$sink_obs"; then
    root_ok observer_failure_missing_observation_unknown
  else
    root_no observer_failure_missing_observation_unknown
  fi
  local capture_obs="$fixture/diag-root-observer/BRIDGE-DIAG-003/guard-capture.jsonl"
  if python3 "$PKG/bin/assert_guard_capture.py" --capture "$capture_obs" \
       --call-id obs-block2 --target-basename guard-blocked-observer \
       --task BRIDGE-DIAG-003 >/dev/null; then
    root_ok observer_failure_guard_still_blocks
  else
    root_no observer_failure_guard_still_blocks
  fi

  snapshot_host "$fixture/host.after"; record "$fixture/host.after"
  if grep -q UNREADABLE "$fixture/host.before" "$fixture/host.after"; then
    root_no host_isolation_snapshot_unreadable
  elif cmp -s "$fixture/host.before" "$fixture/host.after"; then
    root_ok host_isolation_scope_registry_bridge_diag_run
  else
    root_no host_isolation_changed
  fi

  local pid
  for pid in "${UP_PIDS[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null || true; done
  for pid in "${UP_PIDS[@]:-}"; do [ -n "$pid" ] && wait "$pid" 2>/dev/null || true; done
  UP_PIDS=()

  if [ "$ROOT_FAIL" -ne 0 ]; then
    echo "OBS_CHECK=FAIL failures=$ROOT_FAIL"
    echo "SCENE_KEPT=$fixture"
    exit 1
  fi

  if [ -e "$fixture/repo/.git" ] && [ -d "$fixture/task/project" ]; then
    clean_worktree_product "$fixture/repo" "$fixture/task/project" \
      "$fixture/task/project/observer-alive" aegl-ai \
      || { echo "OBS_CHECK=FAIL phase=cleanup_worktree_product"; echo "SCENE_KEPT=$fixture"; exit 1; }
  fi
  local p
  while IFS= read -r p; do
    case "$p" in "$fixture/diag-root"*|"$fixture"|"$fixture/task/project"*) continue ;; esac
    if [ -f "$p" ] || [ -L "$p" ]; then
      rm -f -- "$p" || { echo "OBS_CHECK=FAIL phase=cleanup_file"; echo "SCENE_KEPT=$fixture"; exit 1; }
    fi
  done < "$rec"
  while IFS= read -r p; do
    case "$p" in "$fixture/diag-root"*|"$fixture") continue ;; esac
    if [ -d "$p" ]; then
      rmdir -- "$p" || { echo "OBS_CHECK=FAIL phase=cleanup_dir"; echo "SCENE_KEPT=$fixture"; exit 1; }
    fi
  done < <(sort -r "$rec")
  rm -f "$rec" || { echo "OBS_CHECK=FAIL phase=cleanup_record"; echo "SCENE_KEPT=$fixture"; exit 1; }
  echo "EVIDENCE_DIR_MAIN=$fixture/diag-root/BRIDGE-DIAG-003"
  echo "EVIDENCE_DIR_OBSERVER=$fixture/diag-root-observer/BRIDGE-DIAG-003"
  echo "OBS_CHECK=PASS"
  exit 0
}

case "$MODE" in
  self-test) self_test ;;
  full) root_check ;;
esac
