#!/usr/bin/env bash
# AEGL-TOOL-OBS-CHECK-r1 entry.
#
#   --self-test   ordinary-user checks only (hashes, Hermes version, manifest, fixture
#                 templates, HTTPS synthetic upstream, hook wiring). No root, no sandbox.
#   default       root-only isolated check: real launcher --check, real Hermes tool
#                 executor under bwrap, real pre/post hooks, guard block, host isolation.
#
# The synthetic upstream is local and HTTPS (the model-config validator requires HTTPS);
# it returns fixed harmless tool calls and never contacts a real model service.
set -uo pipefail

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

check_candidates() {
  local rel got
  for rel in "${!WANT[@]}"; do
    got="$(sha256sum "$PKG/$rel" 2>/dev/null | awk '{print $1}')"
    [ "$got" = "${WANT[$rel]}" ] && ok "candidate_hash $rel" || no "candidate_hash $rel (${got:-missing})"
  done
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
  python3 -m py_compile "$PKG/bin/fake_upstream.py" "$PKG/bin/assert_observation.py" \
    && ok "check_python_syntax" || no "check_python_syntax"
}

make_contract() { # <dir>
  local dir="$1"
  mkdir -p "$dir"
  python3 - "$dir" <<'PY'
import json, sys
d = sys.argv[1]
json.dump({"contract_id": "OBS-CLI-001", "allowed_paths": ["project"],
           "forbidden_paths": [], "read_first": []},
          open(d + "/implementation-contract.json", "w"))
json.dump({"project": "obs-check", "source_root": "/tmp/obs-check-task",
           "read_first": [], "allowed_paths": ["project"], "forbidden_paths": []},
          open(d + "/project-context.json", "w"))
PY
}

check_contract_fixture() {
  local tmp; tmp="$(mktemp -d /var/tmp/aegl-obs-ct.XXXXXX)" || { no contract_fixture; return; }
  make_contract "$tmp/contract"
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

check_fake_upstream() {
  local tmp; tmp="$(mktemp -d /var/tmp/aegl-obs-tls.XXXXXX)" || { no fake_upstream_https; return; }
  if ! openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
       -days 1 -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" \
       -addext "basicConstraints=critical,CA:TRUE" >/dev/null 2>&1; then
    no fake_upstream_https; rm -f "$tmp"/*; rmdir "$tmp"; return
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
import http.client, json, os, ssl, sys
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
  rm -f "$tmp/cert.pem" "$tmp/key.pem" "$tmp/port" "$tmp/blocked"
  rmdir "$tmp" 2>/dev/null || true
}

self_test() {
  say "SELF_TEST begin pkg=$PKG"
  check_candidates
  check_hermes
  check_manifest
  check_syntax
  check_contract_fixture
  check_profile_fixture
  check_model_config_fixture
  check_fake_upstream
  notrun root_bwrap_check_mode_sink_absence
  notrun root_bwrap_real_tool_executor
  notrun root_bwrap_guard_block_no_execution
  notrun root_bwrap_observer_failure_independence
  notrun host_isolation
  say "SELF_TEST pass=$PASS fail=$FAIL"
  [ "$FAIL" -eq 0 ]
}

# --- root-only isolated check ---------------------------------------------------------
ROOT_FAIL=0
root_no() { ROOT_FAIL=$((ROOT_FAIL + 1)); printf 'FAIL %s %s\n' "$1" "${2:-}"; }
root_ok() { printf 'PASS %s\n' "$1"; }

snapshot_host() {
  local out="$1"
  {
    sha256sum /var/lib/aegl-model/registry.json 2>/dev/null || true
    sha256sum /home/zhong/.local/state/google-android-agent-stack/bridge/state.json 2>/dev/null || true
    stat -c '%n %F %s %Y' /var/tmp/aegl-diag/BRIDGE-DIAG-003 2>/dev/null || true
    stat -c '%n %F %s %Y' /run/aegl-model/BRIDGE-DIAG-003 2>/dev/null || true
  } > "$out"
}

root_check() {
  [ "$(id -u)" -eq 0 ] || { echo "NOT_RUN root_required"; exit 1; }
  for tool in unshare bwrap openssl setpriv git; do
    command -v "$tool" >/dev/null || { echo "NOT_RUN missing_$tool"; exit 1; }
  done
  id -u aegl-ai >/dev/null 2>&1 || { echo "NOT_RUN missing_aegl_ai"; exit 1; }

  check_candidates
  check_hermes
  check_manifest
  check_syntax
  check_contract_fixture
  check_profile_fixture
  check_model_config_fixture

  [ "$FAIL" -eq 0 ] || { echo "OBS_CHECK=FAIL prechecks=$FAIL"; exit 1; }

  local fixture="/var/tmp/AEGL-TOOL-OBS-CHECK.r1.$$"
  install -d -o root -g root -m 0700 "$fixture" || { echo "FIXTURE_FAILED $fixture"; exit 1; }
  local rec="$fixture/.created"
  : > "$rec"
  record() { printf '%s\n' "$1" >> "$rec"; }
  trap 'rc=$?; [ -n "${up_pid:-}" ] && kill "$up_pid" 2>/dev/null; if [ "$rc" -ne 0 ] || [ "$ROOT_FAIL" -ne 0 ]; then echo "SCENE_KEPT=$fixture"; fi' EXIT

  install -d -m 0755 "$fixture/task" "$fixture/task/project" "$fixture/task/scratch" \
    "$fixture/repo" "$fixture/contract" "$fixture/diag-root" "$fixture/run-root" \
    "$fixture/tls" "$fixture/profile" || { echo "FIXTURE_FAILED dirs"; exit 1; }
  for d in "$fixture" "$fixture/task" "$fixture/task/project" "$fixture/task/scratch" \
           "$fixture/repo" "$fixture/contract" "$fixture/diag-root" "$fixture/run-root" \
           "$fixture/tls" "$fixture/profile"; do record "$d"; done
  chown aegl-ai:aegl-ai "$fixture/task/project" "$fixture/task/scratch"
  chmod 0750 "$fixture/task/scratch"

  snapshot_host "$fixture/host.before"
  record "$fixture/host.before"

  # synthetic HTTPS upstream
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$fixture/tls/key.pem" \
    -out "$fixture/tls/cert.pem" -days 1 -subj "/CN=127.0.0.1" \
    -addext "subjectAltName=IP:127.0.0.1" \
    -addext "basicConstraints=critical,CA:TRUE" >/dev/null 2>&1 \
    || { echo "FIXTURE_FAILED tls"; exit 1; }
  record "$fixture/tls/key.pem"; record "$fixture/tls/cert.pem"
  python3 "$PKG/bin/fake_upstream.py" --cert "$fixture/tls/cert.pem" \
    --key "$fixture/tls/key.pem" --port-file "$fixture/port" \
    --block-path "$fixture/task/scratch/guard-blocked" >/dev/null 2>&1 &
  local up_pid=$!
  local i; for i in $(seq 1 100); do [ -s "$fixture/port" ] && break; sleep 0.05; done
  local port; port="$(cat "$fixture/port" 2>/dev/null || true)"
  [ -n "$port" ] || { echo "FIXTURE_FAILED upstream"; kill "$up_pid" 2>/dev/null; exit 1; }
  record "$fixture/port"

  # contract / profile / model config / registry / prompt
  python3 - "$fixture" <<'PY'
import json, sys
f = sys.argv[1]
json.dump({"contract_id": "OBS-CLI-001", "allowed_paths": ["project"],
           "forbidden_paths": [], "read_first": []},
          open(f + "/contract/implementation-contract.json", "w"))
json.dump({"project": "obs-check", "source_root": f + "/task",
           "read_first": [], "allowed_paths": ["project"], "forbidden_paths": []},
          open(f + "/contract/project-context.json", "w"))
json.dump({"BRIDGE-DIAG-003": {
    "worktree": f + "/task/project", "scratch": f + "/task/scratch",
    "project": f + "/repo", "contract_package": f + "/contract"}},
    open(f + "/registry.json", "w"))
PY
  record "$fixture/contract/implementation-contract.json"
  record "$fixture/contract/project-context.json"
  record "$fixture/registry.json"

  cat > "$fixture/profile.yaml" <<EOF
hooks:
  pre_tool_call:
    - command: '/usr/bin/python3 $PKG/bin/guard/contract_guard.py'
      matcher: write_file|patch|terminal
      fail_closed: true
      timeout: 20
EOF
  record "$fixture/profile.yaml"
  : > "$fixture/cred.env"; record "$fixture/cred.env"
  printf 'AEGL_OBS_DUMMY=dummy\n' > "$fixture/cred.env"
  cat > "$fixture/model.config" <<EOF
MODEL_API=openai-chat-completions
UPSTREAM=https://127.0.0.1:$port
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
  record "$fixture/model.config"
  printf 'Run the fixed local observation checks.\n' > "$fixture/prompt.txt"
  record "$fixture/prompt.txt"

  # fixture Git repo + registered worktree (root repo, aegl-ai worktree)
  git init -q "$fixture/repo" || { echo "FIXTURE_FAILED git"; exit 1; }
  printf 'plan\n' > "$fixture/repo/PLAN.md"
  git -C "$fixture/repo" add PLAN.md
  git -C "$fixture/repo" -c user.name=obs -c user.email=obs@local commit -qm base
  git -C "$fixture/repo" worktree add -q "$fixture/task/project" -b obs-check
  chown -R aegl-ai:aegl-ai "$fixture/task/project"
  find "$fixture" -type f -not -path "$fixture/diag-root/*" -not -name .created \
    -not -path "$fixture/task/project/*" 2>/dev/null | while IFS= read -r p; do record "$p"; done
  find "$fixture" -type d -not -path "$fixture/diag-root*" -not -path "$fixture/task/project/*" \
    -not -name .created 2>/dev/null | while IFS= read -r p; do record "$p"; done

  run_ns() {
    unshare --mount --propagation private -- bash -c '
      set -e
      mount --bind "$1/diag-root" /var/tmp/aegl-diag
      mount --bind "$1/run-root" /run/aegl-model
      shift
      exec "$@"
    ' _ "$fixture" env AEGL_MODEL_CONFIG="$fixture/model.config" \
      AEGL_MODEL_TASK_REGISTRY="$fixture/registry.json" \
      AEGL_MODEL_LIBDIR="$PKG/bin" SSL_CERT_FILE="$fixture/tls/cert.pem" "$@"
  }

  # 1. launcher --check: guard-only, no task sink
  local out rc=0
  out="$(run_ns "$PKG/bin/aegl-hermes-sandbox" --task BRIDGE-DIAG-003 \
         --check "printf OBS_CHECK_OK" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'SANDBOX_CHECK_RC=0' \
     && printf '%s' "$out" | grep -q 'OBS_CHECK_OK' \
     && printf '%s' "$out" | grep -q 'allowlist=1' \
     && [ ! -e "$fixture/diag-root/BRIDGE-DIAG-003" ]; then
    root_ok check_mode_guard_only_no_sink
  else
    printf '%s\n' "$out"
    root_no check_mode_guard_only_no_sink
  fi

  # 2. real Hermes tool executor under bwrap + real hooks
  rc=0
  out="$(run_ns "$PKG/bin/aegl-hermes-sandbox" --task BRIDGE-DIAG-003 -- \
         hermes -p android-stack chat --oneshot --query-file "$fixture/prompt.txt" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out"
    root_no real_tool_executor_exit "rc=$rc"
  else
    root_ok real_tool_executor_exit
  fi
  local sink="$fixture/diag-root/BRIDGE-DIAG-003/events.jsonl"
  if [ -f "$sink" ] \
     && python3 "$PKG/bin/assert_observation.py" --events "$sink" \
          --forbidden "$fixture/task/scratch/guard-blocked" --fixture "$fixture"; then
    root_ok real_pre_post_sink_and_guard_block
  else
    root_no real_pre_post_sink_and_guard_block
  fi
  [ ! -e "$fixture/run-root/BRIDGE-DIAG-003" ] && root_ok run_dir_removed \
    || root_no run_dir_removed
  [ -f "$sink" ] && root_ok sink_survives_run_dir_removal || root_no sink_survives_run_dir_removal

  snapshot_host "$fixture/host.after"
  record "$fixture/host.after"
  if cmp -s "$fixture/host.before" "$fixture/host.after"; then
    root_ok host_isolation
  else
    root_no host_isolation
  fi

  kill "$up_pid" 2>/dev/null; wait "$up_pid" 2>/dev/null || true

  if [ "$ROOT_FAIL" -ne 0 ]; then
    echo "OBS_CHECK=FAIL failures=$ROOT_FAIL"
    echo "SCENE_KEPT=$fixture"
    exit 1
  fi

  # cleanup: normal worktree removal, explicit recorded files, then recorded dirs;
  # keep the diagnostic sink as the evidence.
  if [ -e "$fixture/repo/.git" ] && [ -d "$fixture/task/project" ]; then
    git -C "$fixture/repo" worktree remove "$fixture/task/project" \
      || { echo "CLEANUP_FAILED worktree"; echo "SCENE_KEPT=$fixture"; exit 1; }
  fi
  while IFS= read -r p; do
    case "$p" in "$fixture/diag-root"*|"$fixture"|"$fixture/task/project"*) continue ;; esac
    if [ -f "$p" ] || [ -L "$p" ]; then rm -f -- "$p" || { echo "CLEANUP_FAILED $p"; exit 1; }; fi
  done < "$rec"
  while IFS= read -r p; do
    case "$p" in "$fixture/diag-root"*|"$fixture") continue ;; esac
    [ -d "$p" ] && rmdir -- "$p" 2>/dev/null || true
  done < <(sort -r "$rec")
  rm -f "$rec"
  echo "EVIDENCE_DIR=$fixture/diag-root/BRIDGE-DIAG-003"
  echo "OBS_CHECK=PASS"
  exit 0
}

case "$MODE" in
  self-test) self_test ;;
  full) root_check ;;
esac
