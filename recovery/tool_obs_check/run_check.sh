#!/usr/bin/env bash
# AEGL-TOOL-OBS-CHECK-r7 entry.
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

OWNER="zhong"
OWNER_HOME="/home/zhong"
OWNER_HERMES_HOME="/home/zhong/.hermes"
OWNER_PATH="/usr/local/bin:/usr/bin:/bin"
OWNER_LANG="C.UTF-8"
HERMES_RUNTIME="$OWNER_HERMES_HOME/hermes-agent"
HERMES_HOME="$OWNER_HERMES_HOME"
HERMES_BIN="$HERMES_RUNTIME/.hermes/bin/hermes"
HERMES_COMMIT="af90026aa09949579bd423d24def3d38f743cde0"
HERMES_VERSION_MARK="v0.21.5+6977.gaf90026"
RUNUSER="$(command -v runuser 2>/dev/null || true)"

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

classify_hermes_error() { # <in-memory output> — whitelisted category only
  case "$1" in
    *"No such file or directory"*|*"not found"*) echo binary_missing ;;
    *"Permission denied"*) echo permission ;;
    *"not a git repository"*) echo not_repo ;;
    *"dubious ownership"*) echo ownership ;;
    *"does not exist"*|*"runuser"*) echo runner ;;
    *"HERMES_HOME"*|*"hermes_home"*|*".hermes"*) echo home ;;
    *) echo UNKNOWN ;;
  esac
}

run_as_hermes_owner() { # minimal explicit context; root drops to the install owner
  local -a envv=(/usr/bin/env -i "HOME=$OWNER_HOME" "HERMES_HOME=$OWNER_HERMES_HOME"
                 "PATH=$OWNER_PATH" "LANG=$OWNER_LANG")
  if [ "$(id -u)" -eq 0 ]; then
    [ -n "$RUNUSER" ] || return 127
    "$RUNUSER" -u "$OWNER" -- "${envv[@]}" "$@"
  else
    "${envv[@]}" "$@"
  fi
}

check_hermes_context() {
  local out rc=0 owner home hermes_home
  out="$(run_as_hermes_owner /bin/sh -c \
        'printf "%s\n%s\n%s\n" "$(id -un)" "$HOME" "$HERMES_HOME"' 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    no "hermes_context category=probe_failed rc=$rc"
    return
  fi
  { IFS= read -r owner; IFS= read -r home; IFS= read -r hermes_home; } <<< "$out"
  if [ "$owner" != "$OWNER" ] || [ "$home" != "$OWNER_HOME" ] \
     || [ "$hermes_home" != "$OWNER_HERMES_HOME" ]; then
    no "hermes_context category=context_mismatch rc=0"
    return
  fi
  ok "hermes_context"
}

check_hermes_version_at() { # <binary>
  local binary="$1" out rc=0 cat
  out="$(run_as_hermes_owner "$binary" --version 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    cat="$(classify_hermes_error "$out")"
    no "hermes_version category=$cat rc=$rc"
    return
  fi
  case "$out" in
    *"$HERMES_VERSION_MARK"*) ok "hermes_version" ;;
    *) no "hermes_version category=version_mismatch rc=0" ;;
  esac
}

check_hermes_commit_at() { # <runtime>
  local runtime="$1" out rc=0 cat
  out="$(run_as_hermes_owner git -C "$runtime" rev-parse HEAD 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    cat="$(classify_hermes_error "$out")"
    no "hermes_commit category=$cat rc=$rc"
    return
  fi
  case "$out" in
    "$HERMES_COMMIT") ok "hermes_commit" ;;
    *) no "hermes_commit category=commit_mismatch rc=0" ;;
  esac
}

check_hermes() {
  check_hermes_context
  check_hermes_version_at "$HERMES_BIN"
  check_hermes_commit_at "$HERMES_RUNTIME"
}

check_hermes_negatives() {
  local tmp; tmp="$(mktemp -d /var/tmp/aegl-obs-hv.XXXXXX)" || { no hermes_negatives; return; }
  cat > "$tmp/bad_hermes" <<'SH'
#!/bin/sh
echo "No such file or directory" >&2
exit 7
SH
  cat > "$tmp/wrong_hermes" <<'SH'
#!/bin/sh
echo "v0.0.0"
exit 0
SH
  chmod 0755 "$tmp/bad_hermes" "$tmp/wrong_hermes"
  local bad=0 out
  out="$( ( check_hermes_version_at "$tmp/bad_hermes" ) 2>&1 )"
  case "$out" in *"FAIL hermes_version category=binary_missing rc=7"*) ;; *) bad=1 ;; esac
  case "$out" in *"PASS hermes_version"*) bad=1 ;; esac
  out="$( ( check_hermes_version_at "$tmp/wrong_hermes" ) 2>&1 )"
  case "$out" in *"FAIL hermes_version category=version_mismatch rc=0"*) ;; *) bad=1 ;; esac
  case "$out" in *"PASS hermes_version"*) bad=1 ;; esac
  install -d "$tmp/nonrepo"
  out="$( ( check_hermes_commit_at "$tmp/nonrepo" ) 2>&1 )"
  case "$out" in *"FAIL hermes_commit"*"rc="*) ;; *) bad=1 ;; esac
  case "$out" in *"PASS hermes_commit"*) bad=1 ;; esac
  if git init -q "$tmp/repo" \
     && git -C "$tmp/repo" -c user.name=t -c user.email=t@x commit -q --allow-empty -m base; then
    out="$( ( check_hermes_commit_at "$tmp/repo" ) 2>&1 )"
    case "$out" in *"FAIL hermes_commit category=commit_mismatch rc=0"*) ;; *) bad=1 ;; esac
    case "$out" in *"PASS hermes_commit"*) bad=1 ;; esac
  else
    bad=1
  fi
  [ "$bad" -eq 0 ] && ok hermes_negatives || no hermes_negatives
  if [ -d "$tmp/repo" ]; then
    find "$tmp/repo" -type f 2>/dev/null | while IFS= read -r p; do rm -f "$p"; done
    find "$tmp/repo" -depth -type d 2>/dev/null | while IFS= read -r p; do rmdir "$p" 2>/dev/null || true; done
  fi
  rm -f "$tmp/bad_hermes" "$tmp/wrong_hermes"
  rmdir "$tmp/nonrepo" "$tmp" 2>/dev/null || true
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
             "assert_guard_capture.py", "guard_capture.py", "broker_guard_capture_test.py",
             "openai_protocol_test.py"):
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
 {"phase": "tool_post_observe", "seq": 2, "arg": "src=hook trust=diagnostic when=post corr=1 tool=terminal status=ERROR err=tool_error duration_ms=2 exit=1"},
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
  local allow_rc=0 allow_out
  allow_out="$(python3 "$PKG/bin/assert_observation.py" --events "$tmp/valid" \
               --forbidden "$tmp/none" 2>&1)" || allow_rc=$?
  local bad=0
  mutate_sink "$tmp/valid" "$tmp/pre_seq1" "rows[:] = [({**r, 'seq': 1}) if r.get('phase') == 'tool_pre_observe' else r for r in rows]"
  mutate_sink "$tmp/valid" "$tmp/exit10" "rows[:] = [({**r, 'arg': r['arg'].replace('exit=1', 'exit=10')}) if r.get('phase') == 'tool_post_observe' and r.get('seq') == 2 else r for r in rows]"
  mutate_sink "$tmp/valid" "$tmp/missing_post" "rows[:] = [r for i, r in enumerate(rows) if not (r.get('phase') == 'tool_post_observe' and r.get('seq') == 2)]"
  mutate_sink "$tmp/valid" "$tmp/duplicate_post" "rows[:] = rows + [next(r for r in rows if r.get('phase') == 'tool_post_observe' and r.get('seq') == 1)]"
  mutate_sink "$tmp/valid" "$tmp/extra_pre" "rows[:] = rows + [{'phase': 'tool_pre_observe', 'seq': 4, 'arg': 'src=hook trust=diagnostic when=pre corr=1 tool=terminal status=OK err=UNKNOWN'}]"
  mutate_sink "$tmp/valid" "$tmp/post_before_pre" "rows[:] = [r for r in rows if r.get('phase') == 'model_response'] + [r for r in rows if r.get('phase') == 'model_tool_request'] + [r for r in rows if r.get('phase') == 'tool_post_observe'] + [r for r in rows if r.get('phase') == 'tool_pre_observe']"
  # Structural negatives: a fourth request, a repeated announcement with no new
  # pre/post, and fewer than three requests must all FAIL without an IndexError.
  mutate_sink "$tmp/valid" "$tmp/extra_request" "rows[:] = rows + [{'phase': 'model_tool_request', 'seq': 4, 'arg': 'resp=10 tool=terminal'}]"
  mutate_sink "$tmp/valid" "$tmp/duplicate_announcement" "rows[:] = rows + [next(r for r in rows if r.get('phase') == 'model_tool_request' and r.get('seq') == 1)]"
  mutate_sink "$tmp/valid" "$tmp/short_requests" "rows[:] = [r for r in rows if not (r.get('phase') == 'model_tool_request' and r.get('seq') == 3)]"
  local name out rc
  for name in pre_seq1 exit10 missing_post duplicate_post extra_pre post_before_pre \
              extra_request duplicate_announcement short_requests; do
    rc=0
    out="$(python3 "$PKG/bin/assert_observation.py" --events "$tmp/$name" \
            --forbidden "$tmp/none" 2>&1)" || rc=$?
    [ "$rc" -ne 0 ] || bad=$((bad + 1))
    case "$out" in *"OBS_ASSERT=FAIL"*) ;; *) bad=$((bad + 1)) ;; esac
    case "$out" in *"OBS_ASSERT=PASS"*) bad=$((bad + 1)) ;; esac
    case "$out" in *Traceback*) bad=$((bad + 1)) ;; esac
  done
  case "$allow_out" in *"OBS_ASSERT=PASS"*) ;; *) bad=$((bad + 1)) ;; esac
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
req = [{"role": "user", "content": "go"}]
TOOLS = [{"type": "function", "function": {
    "name": "terminal", "parameters": {"type": "object", "properties": {}}}}]


def post(body):
    conn.request("POST", "/v1/chat/completions", body=json.dumps(body).encode(),
                 headers={"Content-Type": "application/json"})
    resp = conn.getresponse()
    return resp.getheader("content-type"), resp.read()


# Auxiliary request (no tool declaration): fixed text, no scenario step consumed.
ctype, raw = post({"model": "obs-check", "messages": req})
assert ctype.startswith("application/json")
message = json.loads(raw)["choices"][0]["message"]
assert message["content"] == "done" and not message.get("tool_calls")

# Declared terminal tool: step 0 is still first.
ctype, raw = post({"model": "obs-check", "messages": req, "tools": TOOLS})
assert ctype.startswith("application/json")
call = json.loads(raw)["choices"][0]["message"]["tool_calls"][0]
assert call["id"] == "obs-ok" and call["function"]["name"] == "terminal"

conn.request("GET", "/v1/models")
resp = conn.getresponse()
data = json.loads(resp.read())
assert [m["id"] for m in data["data"]] == ["obs-check"]

ctype, raw = post({"model": "obs-check", "messages": req, "tools": TOOLS,
                   "stream": True})
assert ctype.startswith("text/event-stream")
text = raw.decode()
assert text.startswith("data: ")
assert text.rstrip().endswith("data: [DONE]")
assert '"finish_reason": "tool_calls"' in text

conn.request("POST", "/v1/responses", body=b"{}",
             headers={"Content-Type": "application/json"})
resp = conn.getresponse()
assert resp.status == 404 and resp.getheader("content-type").startswith("application/json")
assert "error" in json.loads(resp.read())

conn.request("GET", "/nope")
resp = conn.getresponse()
assert resp.status == 404 and resp.getheader("content-type").startswith("application/json")
conn.close()
PY
    then ok fake_upstream_https; else no fake_upstream_https; fi
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
  fi
  rm -f "$tmp"/*; rmdir "$tmp" 2>/dev/null || true
}

hermes_venv_python() { # declared Hermes dependency environment (facts.json), not a guess
  python3 - "$HERMES_HOME/installs" <<'PY'
import glob, json, os, sys
for facts in sorted(glob.glob(os.path.join(sys.argv[1], "*", "facts.json"))):
    try:
        data = json.load(open(facts, encoding="utf-8"))
        env = data["packages"]["venv"]["environment"]
    except Exception:
        continue
    python = os.path.join(env, "bin", "python")
    if os.path.isdir(env) and os.access(python, os.X_OK):
        print(python)
        raise SystemExit(0)
raise SystemExit(1)
PY
}

check_protocol() {
  local py; py="$(hermes_venv_python 2>/dev/null || true)"
  if [ -z "$py" ]; then
    no "protocol_sdk_environment"
    return
  fi
  local tmp; tmp="$(mktemp -d /var/tmp/aegl-obs-pr.XXXXXX)" || { no protocol_sdk_environment; return; }
  if ! openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
       -days 1 -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" \
       -addext "basicConstraints=critical,CA:TRUE" >/dev/null 2>&1; then
    no protocol_tls; rm -f "$tmp"/*; rmdir "$tmp" 2>/dev/null || true; return
  fi
  local sdk=0 sdk_ver
  sdk_ver="$( cd "$tmp" && "$py" -I -c 'import openai; print(openai.__version__)' 2>/dev/null )" || sdk=1
  if [ "$sdk" -eq 0 ] && [ -n "$sdk_ver" ]; then ok protocol_sdk_present; else no protocol_sdk_present; fi

  local scheme port_file port args
  local bad=0 runs=0
  for scheme in http https; do
    port_file="$tmp/port-$scheme"
    if [ "$scheme" = https ]; then
      python3 "$PKG/bin/fake_upstream.py" --cert "$tmp/cert.pem" --key "$tmp/key.pem" \
        --port-file "$port_file" --block-path "$tmp/blocked" >/dev/null 2>&1 &
    else
      python3 "$PKG/bin/fake_upstream.py" \
        --port-file "$port_file" --block-path "$tmp/blocked" >/dev/null 2>&1 &
    fi
    local upid=$!
    local i
    for i in $(seq 1 100); do [ -s "$port_file" ] && break; sleep 0.05; done
    port="$(cat "$port_file" 2>/dev/null || true)"
    [ -n "$port" ] || { bad=1; kill "$upid" 2>/dev/null; continue; }
    args=(--base-url "$scheme://127.0.0.1:$port/v1" --block-path "$tmp/blocked")
    [ "$scheme" = https ] && args+=(--ca "$tmp/cert.pem")
    local out rc=0
    out="$( cd "$tmp" && "$py" -I "$PKG/bin/openai_protocol_test.py" "${args[@]}" 2>&1 )" || rc=$?
    if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^PROTOCOL json_steps=3 sse_steps=3 ' \
       && printf '%s' "$out" | grep -q '^PROTOCOL ok=1$'; then
      runs=$((runs + 1))
    else
      bad=1
      local cat
      cat="$(printf '%s' "$out" | sed -n 's/^PROTOCOL FAIL category=\([a-z0-9_]*\).*/\1/p' | head -1)"
      no "protocol_${scheme} rc=$rc category=${cat:-UNKNOWN}"
    fi
    kill "$upid" 2>/dev/null; wait "$upid" 2>/dev/null || true
  done
  [ "$bad" -eq 0 ] && [ "$runs" -eq 2 ] && ok protocol_json_and_sse || no protocol_json_and_sse

  # Negative: the synthetic upstream ignores `stream` (always answers JSON). Its catalog
  # GET and JSON completion stay correct, so the SDK run must fail at the SSE stage, not
  # earlier. Only a `sse_*` category is accepted; `json_*` or a directory failure is not.
  local neg_port_file="$tmp/port-nostream"
  python3 "$PKG/bin/fake_upstream.py" --ignore-stream --port-file "$neg_port_file" \
    --block-path "$tmp/blocked" >/dev/null 2>&1 &
  local negpid=$! i neg_port=""
  for i in $(seq 1 100); do [ -s "$neg_port_file" ] && break; sleep 0.05; done
  neg_port="$(cat "$neg_port_file" 2>/dev/null || true)"
  if [ -n "$neg_port" ]; then
    local negout negrc=0 negcat
    negout="$( cd "$tmp" && "$py" -I "$PKG/bin/openai_protocol_test.py" \
               --base-url "http://127.0.0.1:$neg_port/v1" --block-path "$tmp/blocked" 2>&1 )" \
      || negrc=$?
    negcat="$(printf '%s' "$negout" \
              | sed -n 's/^PROTOCOL FAIL category=\([a-z0-9_]*\).*/\1/p' | head -1)"
    if [ "$negrc" -ne 0 ] \
       && ! printf '%s' "$negout" | grep -q '^PROTOCOL ok=1$' \
       && [ "${negcat#sse_}" != "$negcat" ]; then
      ok protocol_ignores_stream_negative
    else
      no "protocol_ignores_stream_negative category=${negcat:-UNKNOWN}"
    fi
  else
    no protocol_ignores_stream_negative
  fi
  kill "$negpid" 2>/dev/null; wait "$negpid" 2>/dev/null || true
  rm -f "$tmp"/*; rmdir "$tmp" 2>/dev/null || true
}

check_namespace_prepare() {
  # Ordinary-user proof through the same run_ns used by the root entry. unshare,
  # mount, mkdir, chown, chmod and the launcher are stubs here: this proves only the
  # call order, the private-namespace placement and failure propagation. Real root,
  # tmpfs and bind execution remain NOT_RUN.
  local tmp; tmp="$(mktemp -d /var/tmp/aegl-obs-ns.XXXXXX)" \
    || { no namespace_prepare; return; }
  local flag=0
  if (
    install -d "$tmp/stub" "$tmp/diag" "$tmp/run" "$tmp/lib" "$tmp/tls" || exit 1
    : > "$tmp/registry.json" || exit 1
    : > "$tmp/tls/cert.pem" || exit 1
    cat > "$tmp/stub/unshare" <<'SH' || exit 1
#!/bin/sh
[ "$1" = "--mount" ] && [ "$2" = "--propagation" ] && [ "$3" = "private" ] && [ "$4" = "--" ] \
  || { printf 'bad_unshare_args\n' >> "$NS_LOG"; exit 91; }
printf 'unshare\n' >> "$NS_LOG"
if [ "${FAKE_NS_FAIL_STAGE:-}" = "unshare" ]; then
  exit "${FAKE_NS_FAIL_RC:-1}"
fi
FAKE_NS_ENTERED=1; export FAKE_NS_ENTERED
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
[ "$#" -gt 0 ] && shift
exec "$@"
SH
    cat > "$tmp/stub/mount" <<'SH' || exit 1
#!/bin/sh
printf 'mount %s\n' "$*" >> "$NS_LOG"
[ "${FAKE_NS_ENTERED:-}" = "1" ] || { printf 'outside_namespace\n' >> "$NS_LOG"; exit 90; }
case "$*" in
  "-t tmpfs -o mode=0755,nosuid,nodev tmpfs /run") stage=private_run_tmpfs ;;
  "--bind $FAKE_DIAG /var/tmp/aegl-diag") stage=diag_bind ;;
  "--bind $FAKE_RUN /run/aegl-model") stage=run_bind ;;
  *) stage=unknown ;;
esac
if [ "${FAKE_NS_FAIL_STAGE:-}" = "$stage" ]; then exit "${FAKE_NS_FAIL_RC:-1}"; fi
exit 0
SH
    for cmd in mkdir chown chmod; do
      cat > "$tmp/stub/$cmd" <<'SH' || exit 1
#!/bin/sh
printf '%s %s\n' "$(basename "$0")" "$*" >> "$NS_LOG"
[ "${FAKE_NS_ENTERED:-}" = "1" ] || { printf 'outside_namespace\n' >> "$NS_LOG"; exit 90; }
[ "${FAKE_NS_FAIL_STAGE:-}" = "run_target" ] && exit "${FAKE_NS_FAIL_RC:-1}"
exit 0
SH
    done
    cat > "$tmp/stub/launcher" <<'SH' || exit 1
#!/bin/sh
printf 'launcher %s\n' "$*" >> "$NS_LOG"
exit 0
SH
    chmod 0755 "$tmp"/stub/* || exit 1
    export PATH="$tmp/stub:/usr/bin:/bin"
    export NS_LOG="$tmp/log" FAKE_DIAG="$tmp/diag" FAKE_RUN="$tmp/run"
    unset FAKE_NS_FAIL_STAGE FAKE_NS_FAIL_RC FAKE_NS_ENTERED
    bad=0
    host_before="$(stat -c '%F %u:%g %a' /run/aegl-model 2>/dev/null || echo ABSENT)"

    : > "$NS_LOG"
    rc=0
    run_ns "$tmp/status" "$tmp" "$tmp/diag" "$tmp/run" "$tmp/lib" "$tmp/cfg" \
      "$tmp/stub/launcher" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] || bad=1
    [ "$(head -n 1 "$tmp/status" 2>/dev/null)" = "ready 0" ] || bad=1
    [ "$(wc -l < "$NS_LOG")" -eq 8 ] || bad=1
    order="$(sed -n 's/^\([a-z]*\).*/\1/p' "$NS_LOG" | tr '\n' ' ')"
    [ "$order" = "unshare mount mkdir chown chmod mount mount launcher " ] || bad=1
    grep -q '^unshare$' "$NS_LOG" || bad=1
    grep -q '^mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs /run$' "$NS_LOG" || bad=1
    grep -q '^mkdir -p /run/aegl-model$' "$NS_LOG" || bad=1
    grep -q '^chown root:root /run/aegl-model$' "$NS_LOG" || bad=1
    grep -q '^chmod 0755 /run/aegl-model$' "$NS_LOG" || bad=1
    grep -q "^mount --bind $tmp/diag /var/tmp/aegl-diag$" "$NS_LOG" || bad=1
    grep -q "^mount --bind $tmp/run /run/aegl-model$" "$NS_LOG" || bad=1
    grep -q '^launcher ' "$NS_LOG" || bad=1
    grep -q 'noexec' "$NS_LOG" && bad=1
    grep -q '^outside_namespace$' "$NS_LOG" && bad=1
    grep -q '^bad_unshare_args$' "$NS_LOG" && bad=1

    check_ns_fail() { # <stage> <rc> <log-lines> <forbidden-regex>
      local stage="$1" want="$2" lines="$3" forbid="$4" r=0 line got_stage got_rc
      : > "$NS_LOG"; : > "$tmp/status"
      export FAKE_NS_FAIL_STAGE="$stage" FAKE_NS_FAIL_RC="$want"
      run_ns "$tmp/status" "$tmp" "$tmp/diag" "$tmp/run" "$tmp/lib" "$tmp/cfg" \
        "$tmp/stub/launcher" >/dev/null 2>&1 || r=$?
      unset FAKE_NS_FAIL_STAGE FAKE_NS_FAIL_RC
      [ "$r" -ne 0 ] || return 1
      line="$(ns_stage "$tmp/status" "$r")"
      got_stage="${line%% *}"; got_rc="${line##* }"
      [ "$got_stage" = "$stage" ] || return 1
      [ "$got_rc" = "$want" ] || return 1
      [ "$(ns_fail_line "$tmp/status" "$r")" = "phase=$stage rc=$want" ] || return 1
      [ "$(wc -l < "$NS_LOG")" -eq "$lines" ] || return 1
      if [ -n "$forbid" ] && grep -qE "$forbid" "$NS_LOG"; then return 1; fi
      grep -q '^outside_namespace$' "$NS_LOG" && return 1
      grep -q '^bad_unshare_args$' "$NS_LOG" && return 1
      return 0
    }

    check_ns_fail unshare 1 1 '^(mount|mkdir|chown|chmod|launcher)' || bad=1
    check_ns_fail private_run_tmpfs 21 2 '^(mkdir|chown|chmod|launcher)|^mount --bind' || bad=1
    check_ns_fail run_target 13 3 '^(chown|chmod|launcher)|^mount --bind' || bad=1
    check_ns_fail diag_bind 17 6 '^launcher|^mount --bind .* /run/aegl-model' || bad=1
    check_ns_fail run_bind 32 7 '^launcher' || bad=1

    host_after="$(stat -c '%F %u:%g %a' /run/aegl-model 2>/dev/null || echo ABSENT)"
    [ "$host_before" = "$host_after" ] || bad=1
    exit "$bad"
  ); then
    flag=1
  fi
  [ "$flag" -eq 1 ] && ok namespace_prepare || no namespace_prepare
  rm -f "$tmp"/stub/* "$tmp"/*.json "$tmp"/tls/cert.pem "$tmp"/status "$tmp"/log \
    "$tmp"/cfg 2>/dev/null || true
  rmdir "$tmp/stub" "$tmp/diag" "$tmp/run" "$tmp/lib" "$tmp/tls" "$tmp" 2>/dev/null || true
}

self_test() {
  say "SELF_TEST begin pkg=$PKG"
  check_candidates
  check_dependencies
  check_hermes
  check_hermes_negatives
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
  check_namespace_prepare
  check_fake_upstream
  check_protocol
  notrun root_namespace_tmpfs_bind_real
  notrun root_bwrap_check_mode_sink_absence
  notrun root_bwrap_real_tool_executor
  notrun root_bwrap_guard_block_no_execution
  notrun root_bwrap_observer_failure_independence
  notrun root_hermes_runuser_context
  notrun host_isolation
  say "SELF_TEST pass=$PASS fail=$FAIL"
  [ "$FAIL" -eq 0 ]
}

# --- root-only isolated check (prepared; NOT run this round) --------------------------
ROOT_FAIL=0
root_no() { ROOT_FAIL=$((ROOT_FAIL + 1)); printf 'FAIL %s %s\n' "$1" "${2:-}"; }
root_ok() { printf 'PASS %s\n' "$1"; }
UP_PIDS=()

# Captured child output is classified in memory only; it is never printed, truncated
# into the log or persisted. Only a fixed category leaves this function.
classify_run_capture() { # <rc> <in-memory output>
  local rc="$1" out="$2" routes bad
  routes="$(printf '%s\n' "$out" | grep -c '^AEGL_MODEL_ROUTE ' 2>/dev/null || true)"
  bad="$(printf '%s\n' "$out" | sed -n 's/^AEGL_MODEL_ROUTE .*status=\([0-9][0-9]*\).*/\1/p' \
         | grep -vc '^200$' 2>/dev/null || true)"
  if printf '%s' "$out" | grep -qi 'timed out\|timeout'; then
    echo timeout
  elif [ "${bad:-0}" -gt 0 ]; then
    echo upstream_status_error
  elif [ "${routes:-0}" -eq 0 ]; then
    [ "$rc" -eq 0 ] && echo no_route_record || echo exec_failed
  else
    [ "$rc" -eq 0 ] && echo UNKNOWN || echo exec_failed
  fi
}

run_detail() { # <stage> <rc> <in-memory output> — fixed fields only
  printf 'stage=%s rc=%s category=%s' "$1" "$2" "$(classify_run_capture "$2" "$3")"
}

# Evidence counts only (never the captured child output).
sink_counts() { # <events.jsonl>
  python3 - "$1" <<'PY' 2>/dev/null || echo "model_responses=UNKNOWN model_tool_requests=UNKNOWN tool_pre=UNKNOWN tool_post=UNKNOWN"
import json, sys
counts = {"model_responses": 0, "model_tool_requests": 0,
          "tool_pre": 0, "tool_post": 0}
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            phase = json.loads(line).get("phase")
            if phase == "model_response":
                counts["model_responses"] += 1
            elif phase == "model_tool_request":
                counts["model_tool_requests"] += 1
            elif phase == "tool_pre_observe":
                counts["tool_pre"] += 1
            elif phase == "tool_post_observe":
                counts["tool_post"] += 1
except Exception:
    raise SystemExit(1)
print(" ".join("%s=%d" % item for item in counts.items()))
PY
}

capture_counts() { # <guard-capture.jsonl>
  python3 - "$1" <<'PY' 2>/dev/null || echo "captures=UNKNOWN blocks=UNKNOWN"
import json, sys
records = blocks = 0
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            records += 1
            if (json.loads(line).get("verdict") or {}).get("action") == "block":
                blocks += 1
except Exception:
    raise SystemExit(1)
print("captures=%d blocks=%d" % (records, blocks))
PY
}

# Namespace preparation shared by the ordinary-user self-test and the root entry.
# Everything below runs inside the private mount namespace created by unshare:
#   1. a fresh tmpfs on /run (mode=0755,nosuid,nodev; no noexec);
#   2. root:root 0755 /run/aegl-model inside that tmpfs;
#   3. the existing diag bind and the fixture run-root bind.
# The host /run is never used or created. Only a fixed stage name and the real rc
# leave the child through the status file; raw output is never printed.
run_ns() { # <status-file> <fixture> <diag-root> <run-root> <libdir> <config> <cmd...>
  local status="$1" fixture="$2" diag="$3" run="$4" lib="$5" cfg="$6"; shift 6
  : > "$status" || return 125
  unshare --mount --propagation private -- bash -c '
    set -u
    status=$1; diag=$2; run=$3
    fail() { printf "%s %s\n" "$1" "$2" > "$status"; exit "$2"; }
    printf "entered 0\n" > "$status" || exit 125
    mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs /run \
      || { rc=$?; fail private_run_tmpfs "$rc"; }
    mkdir -p /run/aegl-model || { rc=$?; fail run_target "$rc"; }
    chown root:root /run/aegl-model || { rc=$?; fail run_target "$rc"; }
    chmod 0755 /run/aegl-model || { rc=$?; fail run_target "$rc"; }
    mount --bind "$diag" /var/tmp/aegl-diag \
      || { rc=$?; fail diag_bind "$rc"; }
    mount --bind "$run" /run/aegl-model \
      || { rc=$?; fail run_bind "$rc"; }
    printf "ready 0\n" > "$status" || exit 125
    shift 3
    exec "$@"
  ' _ "$status" "$diag" "$run" env AEGL_MODEL_CONFIG="$cfg" \
      AEGL_MODEL_TASK_REGISTRY="$fixture/registry.json" \
      AEGL_MODEL_LIBDIR="$lib" SSL_CERT_FILE="$fixture/tls/cert.pem" "$@"
}

ns_stage() { # <status-file> <outer-rc> — fixed stage and real rc only
  local status="$1" rc="$2" line stage value
  line="$(head -n 1 "$status" 2>/dev/null || true)"
  stage="${line%% *}"
  value="${line##* }"
  case "$stage" in
    ready) printf 'ready %s\n' "$rc" ;;
    entered) printf 'ns_prepare %s\n' "$rc" ;;
    "") printf 'unshare %s\n' "$rc" ;;
    *) if [ "$stage" = "$line" ]; then
         printf 'ns_prepare %s\n' "$rc"
       else
         printf '%s %s\n' "$stage" "$value"
       fi ;;
  esac
}

ns_failure_detail() { # <status-file> <outer-rc> — empty when preparation completed
  local line stage
  line="$(ns_stage "$1" "$2")"
  stage="${line%% *}"
  [ "$stage" = "ready" ] && return 0
  printf 'stage=%s rc=%s\n' "$stage" "${line##* }"
}

ns_fail_line() { # <status-file> <outer-rc> — fixed preflight report
  local line stage
  line="$(ns_stage "$1" "$2")"
  stage="${line%% *}"
  printf 'phase=%s rc=%s\n' "${stage:-unshare}" "${line##* }"
}

snapshot_host() { # <out>
  local out="$1" p st
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
  # Only this explicit host path: existence, type and numeric owner/mode.
  p=/run/aegl-model
  if [ -e "$p" ] || [ -L "$p" ]; then
    if st="$(stat -c '%F uid=%u gid=%g mode=%a' "$p" 2>/dev/null)"; then
      printf 'RUN_TARGET_PRESENT %s %s\n' "$p" "$st" >> "$out"
    else
      printf 'RUN_TARGET_UNREADABLE %s\n' "$p" >> "$out"
    fi
  else
    printf 'RUN_TARGET_ABSENT %s\n' "$p" >> "$out"
  fi
}

root_check() {
  [ "$(id -u)" -eq 0 ] || { echo "NOT_RUN root_required"; exit 1; }
  local tool
  for tool in unshare bwrap openssl setpriv runuser git install; do
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

  record "$fixture/ns.status"
  record "$fixture/ns-check.status"
  record "$fixture/ns-main.status"
  record "$fixture/ns-observer.status"
  local ns_rc=0
  run_ns "$fixture/ns.status" "$fixture" "$fixture/diag-root" "$fixture/run-root" \
    "$fixture/view/bin" "$fixture/model.config" true >/dev/null 2>&1 || ns_rc=$?
  if [ "$ns_rc" -ne 0 ]; then
    echo "OBS_CHECK=FAIL $(ns_fail_line "$fixture/ns.status" "$ns_rc")"
    exit 1
  fi

  local out rc=0 detail
  out="$(run_ns "$fixture/ns-check.status" "$fixture" "$fixture/diag-root" \
         "$fixture/run-root" "$fixture/view/bin" "$fixture/model.config" \
         "$PKG/bin/aegl-hermes-sandbox" --task BRIDGE-DIAG-003 \
         --check "printf probe > $fixture/task/scratch/check-write-probe; printf OBS_CHECK_OK" 2>&1)" || rc=$?
  detail="$(ns_failure_detail "$fixture/ns-check.status" "$rc")"
  if [ -n "$detail" ]; then
    root_no check_mode_guard_only_no_sink "$detail"
    root_no sandbox_identity_can_write_scratch "$detail"
  elif [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'SANDBOX_CHECK_RC=0' \
     && printf '%s' "$out" | grep -q 'OBS_CHECK_OK' \
     && printf '%s' "$out" | grep -q 'allowlist=1' \
     && [ -f "$fixture/task/scratch/check-write-probe" ] \
     && [ "$(stat -c '%U' "$fixture/task/scratch/check-write-probe")" = aegl-ai ] \
     && [ ! -e "$fixture/diag-root/BRIDGE-DIAG-003" ]; then
    root_ok check_mode_guard_only_no_sink
    root_ok sandbox_identity_can_write_scratch
  else
    root_no check_mode_guard_only_no_sink "$(run_detail check_mode "$rc" "$out")"
    root_no sandbox_identity_can_write_scratch "rc=$rc"
  fi
  out=""
  rm -f "$fixture/task/scratch/check-write-probe" \
    || { echo "OBS_CHECK=FAIL phase=probe_cleanup"; exit 1; }

  rc=0
  out="$(run_ns "$fixture/ns-main.status" "$fixture" "$fixture/diag-root" \
         "$fixture/run-root" "$fixture/view/bin" "$fixture/model.config" \
         "$PKG/bin/aegl-hermes-sandbox" --task BRIDGE-DIAG-003 -- \
         hermes -p android-stack chat --oneshot --query-file "$fixture/prompt.txt" 2>&1)" || rc=$?
  detail="$(ns_failure_detail "$fixture/ns-main.status" "$rc")"
  local sink_main="$fixture/diag-root/BRIDGE-DIAG-003/events.jsonl"
  local counts_main
  counts_main="$(sink_counts "$sink_main")"
  if [ -n "$detail" ]; then
    root_no real_tool_executor_exit "$detail"
  elif [ "$rc" -eq 0 ]; then
    root_ok real_tool_executor_exit
  else
    root_no real_tool_executor_exit "$(run_detail tool_executor "$rc" "$out")"
  fi
  out=""
  printf 'OBS_REAL_COUNTS main %s %s\n' "$counts_main" \
    "$(capture_counts "$fixture/diag-root/BRIDGE-DIAG-003/guard-capture.jsonl")"
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
  out="$(run_ns "$fixture/ns-observer.status" "$fixture" "$fixture/diag-root-observer" \
         "$fixture/run-root-observer" "$fixture/deadview/bin" \
         "$fixture/model.observer.config" "$PKG/bin/aegl-hermes-sandbox" \
         --task BRIDGE-DIAG-003 -- \
         hermes -p android-stack chat --oneshot --query-file "$fixture/prompt.txt" 2>&1)" || rc=$?
  detail="$(ns_failure_detail "$fixture/ns-observer.status" "$rc")"
  local sink_obs="$fixture/diag-root-observer/BRIDGE-DIAG-003/events.jsonl"
  if [ -n "$detail" ]; then
    root_no observer_failure_run_exit "$detail"
  elif [ "$rc" -eq 0 ]; then
    root_ok observer_failure_run_exit
  else
    root_no observer_failure_run_exit "$(run_detail observer_run "$rc" "$out")"
  fi
  out=""
  printf 'OBS_REAL_COUNTS observer %s %s\n' "$(sink_counts "$sink_obs")" \
    "$(capture_counts "$fixture/diag-root-observer/BRIDGE-DIAG-003/guard-capture.jsonl")"
  if [ -f "$fixture/task/project/observer-alive" ] \
     && [ "$(cat "$fixture/task/project/observer-alive")" = "alive" ] \
     && [ "$(stat -c '%U' "$fixture/task/project/observer-alive")" = aegl-ai ] \
     && [ ! -e "$fixture/task/scratch/guard-blocked-observer" ]; then
    root_ok observer_failure_allowed_executed_blocked_not
  else
    root_no observer_failure_allowed_executed_blocked_not
  fi
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
