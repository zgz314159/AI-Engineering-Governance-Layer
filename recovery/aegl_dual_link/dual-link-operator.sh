#!/usr/bin/env bash
# Dual-link operator — project-agnostic. No new deploy daemon:
#   A) prepare→submit→host-run (per frozen job, leave TTY open)
#   B) Cursor inbox WAKE → decide/ack
#   C) Chrome control + CDP advisor (no HERMES_TASK_V1)
# `arm` is idempotent: called by command-code wrapper/mod on every session start.
set -euo pipefail

SELF=$(readlink -f "${BASH_SOURCE[0]}")
ROOT=$(dirname "$SELF")
# Prefer formal Projects Stack after dual-link IAP promote (2026-11-22).
_default_stack_jobs() {
  local formal=/home/zhong/Projects/Google-Android-Agent-Development-Stack/orchestration/hermes/supervisor/agent_link_jobs.py
  local iap=/var/tmp/IAP-CONTROL-DEV/stack/orchestration/hermes/supervisor/agent_link_jobs.py
  if [[ -f $formal ]]; then printf '%s\n' "$formal"
  elif [[ -f $iap ]]; then printf '%s\n' "$iap"
  else printf '%s\n' "$formal"
  fi
}
STACK_JOBS_PY=${STACK_JOBS_PY:-$(_default_stack_jobs)}
JOB_ROOT=${JOB_ROOT:-/home/zhong/.local/state/google-android-agent-stack/supervisor/agent-link/jobs}
INBOX=${INBOX:-/home/zhong/.local/state/google-android-agent-stack/supervisor/agent-link/cursor-inbox}
STATE_DIR=${STATE_DIR:-/home/zhong/.local/state/aegl-dual-link}
CONTROL_URL=${CONTROL_URL:-}
CDP=${CDP:-http://127.0.0.1:9333}
PY=(env PYTHONDONTWRITEBYTECODE=1 python3)
PROJECT_CONTROL_PY=$ROOT/project_control.py
QUIET=0
ARM_CWD=${PWD:-.}

die(){ echo "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null || die "missing $1"; }
log(){ [[ $QUIET -eq 1 ]] || echo "$*"; }

mkdir -p "$STATE_DIR" "$INBOX"

resolve_control_url(){
  # Arm/bind must prefer project-control-map over a leftover HERMES_* env
  # (e.g. smoke URL still exported in the parent shell).
  local cwd=${1:-$PWD} project=${2:-} out
  if [[ -n ${CONTROL_URL:-} ]]; then
    printf '%s\n' "$CONTROL_URL"
    return 0
  fi
  if ! out=$(python3 "$PROJECT_CONTROL_PY" resolve --cwd "$cwd" --no-env \
       ${project:+--aegl-project "$project"} 2>/dev/null); then
    return 1
  fi
  printf '%s\n' "$out"
}

state_json(){
  # Split locals: bash expands $job in the same `local` line before assignment.
  local job=$1
  local f="$JOB_ROOT/$job/state.json"
  [[ -f $f ]] || die "no state for $job"
  cat "$f"
}
plan_sha(){ state_json "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["plan_sha256"])'; }
job_status(){ state_json "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])'; }
report_sha(){ state_json "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("report_sha256") or "")'; }

watcher_alive(){
  if [[ -f $INBOX/.watch.pid ]] && kill -0 "$(cat "$INBOX/.watch.pid")" 2>/dev/null; then
    return 0
  fi
  pgrep -f 'dual-link-operator.sh watch-inbox' >/dev/null 2>&1
}

ensure_watcher(){
  if watcher_alive; then
    log "WATCHER_OK pid=$(cat "$INBOX/.watch.pid" 2>/dev/null || echo '?')"
    return 0
  fi
  # Detached watch for Cursor notify; same process model as manual watch-inbox.
  nohup bash "$SELF" watch-inbox >>"$STATE_DIR/watch-inbox.log" 2>&1 &
  disown || true
  sleep 0.3
  if watcher_alive; then
    log "WATCHER_STARTED pid=$(cat "$INBOX/.watch.pid")"
  else
    log "WATCHER_START_UNCERTAIN see $STATE_DIR/watch-inbox.log"
    return 1
  fi
}

cdp_check(){
  local ctrl=${1:?control_url}
  if curl -sS --max-time 2 "$CDP/json/list" >"$STATE_DIR/cdp-tabs.json" 2>/dev/null; then
    python3 - "$ctrl" "$STATE_DIR/cdp-tabs.json" <<'PY'
import json,sys
ctrl, path = sys.argv[1], sys.argv[2]
tabs=json.load(open(path))
hits=[t for t in tabs if (t.get("url") or "") == ctrl or ctrl in (t.get("url") or "")]
print(f"CDP_OK tabs={len(tabs)} control_hits={len(hits)} url={ctrl}")
if not hits:
    print("CONTROL_TAB_MISSING open", ctrl)
    print("HINT: bash ~/.local/share/aegl-dual-link/ensure-cdp-control.sh  # then login if ChatGPT shows 登录")
    sys.exit(2)
PY
  else
    log "CDP_DOWN — start Chrome with --remote-debugging-port=9333"
    return 1
  fi
}

cmd_bind_control(){
  local cwd=$PWD url= project= note=
  while [[ $# -gt 0 ]]; do
    case $1 in
      --cwd) cwd=$2; shift 2 ;;
      --url) url=$2; shift 2 ;;
      --aegl-project) project=$2; shift 2 ;;
      --note) note=$2; shift 2 ;;
      *) die "unknown bind-control arg: $1" ;;
    esac
  done
  [[ -n $url ]] || die "bind-control requires --url https://chatgpt.com/c/<id>"
  python3 "$PROJECT_CONTROL_PY" bind --cwd "$cwd" --url "$url" \
    ${project:+--aegl-project "$project"} ${note:+--note "$note"}
}

continue_running(){
  [[ -f $STATE_DIR/continue.pid ]] || return 1
  kill -0 "$(cat "$STATE_DIR/continue.pid")" 2>/dev/null
}

# Background prepare→submit→host-run when queue has work (command-code session-up / watcher).
kick_continue_bg(){
  local why=${1:-session-up}
  mkdir -p "$STATE_DIR"
  local n
  n=$(queue_len)
  if [[ "$n" -le 0 ]]; then
    echo "HERMES_WAITING_CONTRACT queue=0 (freeze+enqueue will auto-start Hermes)"
    printf '%s\n' "{\"kind\":\"HERMES_WAITING_CONTRACT\",\"written_at\":$(date +%s),\"hint\":\"freeze contract then enqueue; watcher auto-continues\"}" \
      >"$STATE_DIR/SESSION.json"
    return 0
  fi
  if continue_running; then
    echo "HERMES_EXEC_ALREADY_RUNNING pid=$(cat "$STATE_DIR/continue.pid") queue=$n"
    return 0
  fi
  if ! prepare_nopasswd_ok; then
    echo "HERMES_BLOCKED_PREPARE_NOPASSWD — bash $ROOT/install-nopasswd-prepare.sh" >&2
    return 1
  fi
  # shellcheck disable=SC1091
  [[ -f $STATE_DIR/last-env.sh ]] && . "$STATE_DIR/last-env.sh" || true
  export AEGL_DUAL_LINK_AUTO_DECIDE=${AEGL_DUAL_LINK_AUTO_DECIDE:-1}
  nohup bash -c "
    flock -n '$STATE_DIR/continue.lock' -c '
      echo \$\$ >\"$STATE_DIR/continue.pid\"
      \"$SELF\" continue
      ec=\$?
      rm -f \"$STATE_DIR/continue.pid\"
      exit \$ec
    '
  " >>"$STATE_DIR/continue-auto.log" 2>&1 &
  disown || true
  sleep 0.4
  if continue_running; then
    echo "HERMES_EXEC_STARTED why=$why pid=$(cat "$STATE_DIR/continue.pid") queue=$n log=$STATE_DIR/continue-auto.log"
    printf '%s\n' "{\"kind\":\"HERMES_EXEC_STARTED\",\"why\":\"$why\",\"queue\":$n,\"pid\":$(cat "$STATE_DIR/continue.pid"),\"written_at\":$(date +%s)}" \
      >"$STATE_DIR/SESSION.json"
    return 0
  fi
  echo "HERMES_EXEC_START_UNCERTAIN see $STATE_DIR/continue-auto.log" >&2
  return 1
}

hermes_runtime_probe(){
  local ok=1
  command -v hermes >/dev/null 2>&1 || { echo "HERMES_BIN=MISSING"; ok=0; }
  [[ -f $STACK_JOBS_PY ]] || { echo "STACK_JOBS_PY=MISSING"; ok=0; }
  if prepare_nopasswd_ok; then echo "PREPARE_NOPASSWD=OK"; else echo "PREPARE_NOPASSWD=MISSING"; ok=0; fi
  if [[ $ok -eq 1 ]]; then echo "HERMES_RUNTIME=READY"; return 0; fi
  echo "HERMES_RUNTIME=DEGRADED"
  return 1
}

cmd_session_up(){
  # Called after arm (command-code every chat): CDP + runtime probe + auto Hermes if queued.
  local cwd=${1:-${ARM_CWD:-$PWD}}
  bash "$ROOT/ensure-cdp-control.sh" "$cwd" >/dev/null 2>&1 || true
  hermes_runtime_probe || true
  kick_continue_bg session-up || true
}

cmd_arm(){
  local cwd=$ARM_CWD
  local do_session=${AEGL_DUAL_LINK_SESSION_UP:-1}
  while [[ $# -gt 0 ]]; do
    case $1 in
      --quiet|-q) QUIET=1; shift ;;
      --cwd) cwd=$2; shift 2 ;;
      --session-up) do_session=1; shift ;;
      --no-session-up) do_session=0; shift ;;
      *) shift ;;
    esac
  done
  # Job workspaces / agent-link paths are not coding roots. Prefer the last
  # bound RILI/calendar cwd so command-code reloads do not drift ARM.cwd.
  case $cwd in
    */agent-link/jobs/*|/tmp/*|/var/tmp/RILI-WPF-V2/*/project)
      if [[ -d /home/zhong/EXE/RILI ]] && resolve_control_url /home/zhong/EXE/RILI >/dev/null 2>&1; then
        cwd=/home/zhong/EXE/RILI
      fi
      ;;
  esac
  mkdir -p "$STATE_DIR"
  local ctrl now cdp_st=DOWN watch_st=DOWN
  now=$(date -Iseconds)
  if ! ctrl=$(resolve_control_url "$cwd" 2>"$STATE_DIR/arm.err"); then
    log "CONTROL_BIND_REQUIRED cwd=$cwd"
    log "Create a dedicated ChatGPT chat for this project, keep it open in Chrome (CDP :9333), then:"
    log "  $SELF bind-control --cwd $cwd --url 'https://chatgpt.com/c/<new-conversation-id>'"
    cat "$STATE_DIR/arm.err" >&2 || true
    return 2
  fi
  export HERMES_CHATGPT_CONTROL_URL=$ctrl
  export AEGL_DUAL_LINK_AUTO_DECIDE=${AEGL_DUAL_LINK_AUTO_DECIDE:-1}
  if cdp_check "$ctrl" >/dev/null 2>&1; then cdp_st=OK; else
    bash "$ROOT/ensure-cdp-control.sh" "$cwd" >/dev/null 2>&1 || true
    if cdp_check "$ctrl" >/dev/null 2>&1; then cdp_st=OK; else cdp_check "$ctrl" || true; fi
  fi
  if ensure_watcher; then watch_st=OK; fi
  python3 - "$STATE_DIR/ARM.json" "$cwd" "$now" "$cdp_st" "$watch_st" "$ctrl" <<'PY'
import json,sys,os
path, cwd, now, cdp, watch, ctrl = sys.argv[1:7]
rec={
  "armed_at": now,
  "cwd": os.path.abspath(cwd),
  "project": os.path.basename(os.path.abspath(cwd)),
  "cdp": cdp,
  "watcher": watch,
  "control_url": ctrl,
  "auto_decide": os.environ.get("AEGL_DUAL_LINK_AUTO_DECIDE","1"),
  "rings": {"A_execute":"prepare→submit→host-run --auto-decide",
            "B_decide":"auto-decide inside host-run (Cursor post-facto)",
            "C_advisor":"per-project ChatGPT conversation only"},
  "pid": os.getpid(),
}
open(path,"w").write(json.dumps(rec, ensure_ascii=False, indent=2)+"\n")
print(json.dumps({"status":"ARMED","cdp":cdp,"watcher":watch,"cwd":rec["cwd"],"control_url":ctrl}, ensure_ascii=False))
PY
  local arm_wake
  arm_wake=$(python3 -c 'import json,time,os,sys; print(json.dumps({"kind":"DUAL_LINK_ARMED","cwd":os.path.abspath(sys.argv[1]),"control_url":sys.argv[2],"written_at":time.time()},ensure_ascii=False))' "$cwd" "$ctrl")
  printf '%s\n' "$arm_wake" >"$STATE_DIR/ARM_WAKE"
  printf '%s\n' "$arm_wake" >"$INBOX/DUAL_LINK_ARM"
  # Persist env for subsequent host-run shells
  printf 'export HERMES_CHATGPT_CONTROL_URL=%q\nexport AEGL_DUAL_LINK_AUTO_DECIDE=1\n' "$ctrl" >"$STATE_DIR/last-env.sh"
  log "DUAL_LINK_ARMED cwd=$cwd control_url=$ctrl cdp=$cdp_st watcher=$watch_st auto_decide=1"
  log "host-run will auto CONTINUE/COMPLETE; advisor uses THIS project's ChatGPT tab only."
  if [[ "$do_session" != 0 && "$do_session" != false && "$do_session" != no ]]; then
    cmd_session_up "$cwd"
  fi
}

cmd_status(){
  echo "=== ARM ==="
  [[ -f $STATE_DIR/ARM.json ]] && cat "$STATE_DIR/ARM.json" || echo "(not armed yet)"
  echo
  echo "=== CDP / control ==="
  local ctrl=
  ctrl=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("control_url",""))' \
    "$STATE_DIR/ARM.json" 2>/dev/null || true)
  if [[ -z $ctrl ]]; then
    ctrl=$(resolve_control_url "${PWD:-.}" 2>/dev/null || true)
  fi
  if [[ -n $ctrl ]]; then
    cdp_check "$ctrl" || true
  else
    echo "CONTROL_URL_UNBOUND — bind-control first"
  fi
  echo
  echo "=== prepare NOPASSWD ==="
  if prepare_nopasswd_ok; then
    echo "PREPARE_NOPASSWD_OK /usr/local/sbin/aegl-calendar-prepare"
  else
    echo "PREPARE_NOPASSWD_MISSING — run: bash $ROOT/install-nopasswd-prepare.sh"
  fi
  echo
  echo "=== queue ==="
  [[ -f $STATE_DIR/queue.json ]] && python3 -m json.tool "$STATE_DIR/queue.json" || echo "(empty)"
  echo
  echo "=== Cursor inbox watcher ==="
  if watcher_alive; then
    echo "WATCHER_OK pid=$(cat "$INBOX/.watch.pid" 2>/dev/null || echo '?')"
  else
    echo "WATCHER_NOT_SEEN — arm or: $SELF watch-inbox"
  fi
  echo "WAKE=$(cat "$INBOX/WAKE" 2>/dev/null || true)"
  echo "ARM_WAKE=$(cat "$STATE_DIR/ARM_WAKE" 2>/dev/null || true)"
  echo
  echo "=== Active / recent jobs ==="
  python3 - <<'PY'
import json, pathlib
root=pathlib.Path("/home/zhong/.local/state/google-android-agent-stack/supervisor/agent-link/jobs")
if not root.is_dir():
    print("(no jobs dir)"); raise SystemExit
rows=[]
for d in sorted(root.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True)[:8]:
    s=d/"state.json"
    if not s.exists(): continue
    st=json.loads(s.read_text())
    rows.append((st.get("status"), d.name, st.get("report_number"), (st.get("actions_done") or [])))
for status,jid,n,acts in rows:
    print(f"{status:18} {jid} report#{n} actions={acts}")
PY
}

cmd_host_run(){
  local job=${1:?job_id}
  need python3
  local sha; sha=$(plan_sha "$job")
  # shellcheck disable=SC1091
  [[ -f $STATE_DIR/last-env.sh ]] && . "$STATE_DIR/last-env.sh" || true
  export AEGL_DUAL_LINK_AUTO_DECIDE=${AEGL_DUAL_LINK_AUTO_DECIDE:-1}
  echo "HOST_RUN job=$job plan_sha256=$sha status=$(job_status "$job") auto_decide=$AEGL_DUAL_LINK_AUTO_DECIDE control=${HERMES_CHATGPT_CONTROL_URL:-unbound}"
  echo "Keep this terminal open until COMPLETE/STOP/HUMAN_REQUIRED."
  exec env AEGL_DUAL_LINK_AUTO_DECIDE="$AEGL_DUAL_LINK_AUTO_DECIDE" \
    ${HERMES_CHATGPT_CONTROL_URL:+HERMES_CHATGPT_CONTROL_URL="$HERMES_CHATGPT_CONTROL_URL"} \
    "${PY[@]}" "$STACK_JOBS_PY" host-run \
    --job-id "$job" --thread-id cursor-inbox --plan-sha256 "$sha"
}

cmd_decide_hint(){
  local job=${1:?job_id} st rs
  st=$(job_status "$job"); rs=$(report_sha "$job")
  echo "status=$st report_sha256=$rs"
  case $st in
    WAITING_REVIEW)
      python3 - <<PY
import json
st=json.load(open("$JOB_ROOT/$job/state.json"))
done=set(st.get("actions_done") or [])
action=("execute_contract" if "execute_contract" not in done
        else "host_acceptance" if "host_acceptance" not in done
        else "COMPLETE")
print(action)
if action=="COMPLETE":
    print("""env PYTHONDONTWRITEBYTECODE=1 python3 $STACK_JOBS_PY decide --job-id $job --thread-id cursor-inbox --report-sha256 $rs --decision COMPLETE --instruction 'acceptance passed'
env PYTHONDONTWRITEBYTECODE=1 python3 $STACK_JOBS_PY ack --job-id $job --thread-id cursor-inbox --report-sha256 $rs""")
else:
    print(f"""env PYTHONDONTWRITEBYTECODE=1 python3 $STACK_JOBS_PY decide --job-id $job --thread-id cursor-inbox --report-sha256 $rs --decision CONTINUE --action {action} --instruction go""")
PY
      ;;
    COMPLETE|STOP|HUMAN_REQUIRED) echo "terminal — carry new task_id if continuing" ;;
    *) echo "start host-run or wait for progress" ;;
  esac
}

cmd_watch_inbox(){
  mkdir -p "$INBOX" "$STATE_DIR"
  echo $$ >"$INBOX/.watch.pid"
  [[ -f $INBOX/WAKE ]] && cp -f "$INBOX/WAKE" "$INBOX/.cursor-loop-seen" || true
  [[ -f $INBOX/DUAL_LINK_ARM ]] && cp -f "$INBOX/DUAL_LINK_ARM" "$INBOX/.dual-link-arm-seen" || true
  local last_q=0
  last_q=$(queue_len)
  echo "WATCHING inbox WAKE + DUAL_LINK_ARM + queue auto-continue pid=$$"
  trap 'rm -f "$INBOX/.watch.pid"' EXIT
  while true; do
    sleep 5
    if [[ -f $INBOX/WAKE ]]; then
      cur=$(cat "$INBOX/WAKE" 2>/dev/null || true)
      prev=$(cat "$INBOX/.cursor-loop-seen" 2>/dev/null || true)
      if [[ -n $cur && $cur != "$prev" ]]; then
        printf '%s\n' "$cur" >"$INBOX/.cursor-loop-seen"
        echo 'AGENT_LOOP_WAKE_stack_inbox {"prompt":"【Stack Cursor 收件箱有新回报】读取 LATEST.json；WAITING_REVIEW 则 decide CONTINUE（execute_contract→host_acceptance→COMPLETE+ack）。已消费任务不重放。Chrome 仅顾问纯文本，禁 HERMES_TASK_V1。"}'
      fi
    fi
    if [[ -f $INBOX/DUAL_LINK_ARM ]]; then
      cur=$(cat "$INBOX/DUAL_LINK_ARM" 2>/dev/null || true)
      prev=$(cat "$INBOX/.dual-link-arm-seen" 2>/dev/null || true)
      if [[ -n $cur && $cur != "$prev" ]]; then
        printf '%s\n' "$cur" >"$INBOX/.dual-link-arm-seen"
        echo "AGENT_LOOP_WAKE_dual_link_armed $cur"
      fi
    fi
    # A-ring: any new queued item → auto Hermes host-run (no Cursor pause).
    if [[ ${AEGL_DUAL_LINK_AUTO_CONTINUE:-1} != 0 ]]; then
      local qn
      qn=$(queue_len)
      if [[ "$qn" -gt 0 && ( "$qn" -gt "$last_q" || ! continue_running ) ]]; then
        kick_continue_bg watcher-queue || true
      fi
      last_q=$qn
    fi
  done
}

QUEUE_FILE=$STATE_DIR/queue.json
PREPARE_BIN=/usr/local/sbin/aegl-calendar-prepare

prepare_nopasswd_ok(){
  [[ -x $PREPARE_BIN ]] || return 1
  # Wrapper exits non-zero on argc errors; capture under `|| true` so pipefail
  # does not hide a successful NOPASSWD reachability probe.
  local out
  out=$(sudo -n "$PREPARE_BIN" 2>&1 || true)
  grep -q 'BLOCKED:' <<<"$out"
}

cmd_enqueue(){
  # enqueue --plan /path/to/queue-item.json  (single item or {items:[...]})
  local plan=${1:?queue item json}
  [[ -f $plan ]] || die "enqueue needs json file"
  python3 - "$QUEUE_FILE" "$plan" <<'PY'
import json,sys,time
qf, src = sys.argv[1], sys.argv[2]
raw=json.load(open(src))
items=raw["items"] if isinstance(raw,dict) and "items" in raw else ([raw] if isinstance(raw,dict) else raw)
req={"task_id","task_root","base_commit","manifest_sha256","job_id","evidence","evidence_sha256","acceptance"}
for it in items:
    miss=req-set(it)
    if miss: raise SystemExit(f"queue item missing {sorted(miss)}")
q={"version":1,"items":[]}
try: q=json.load(open(qf))
except FileNotFoundError: pass
except Exception: pass
existing={x.get("job_id") for x in q.get("items",[])}
for it in items:
    if it["job_id"] in existing:
        print(f"SKIP_EXISTS job_id={it['job_id']}")
        continue
    it.setdefault("enqueued_at", time.strftime("%Y-%m-%dT%H:%M:%S%z"))
    it.setdefault("max_runtime_s", 300)
    it.setdefault("max_actions", 3)
    it.setdefault("max_wall_seconds", 3600)
    it.setdefault("worker_model", "deepseek/deepseek-v4.1-flash")
    it.setdefault("project", "OfflineTaskCalendar_WPF")
    q.setdefault("items", []).append(it)
    print(f"ENQUEUED job_id={it['job_id']} task_id={it['task_id']}")
open(qf,"w").write(json.dumps(q, ensure_ascii=False, indent=2)+"\n")
print(f"QUEUE_LEN={len(q.get('items',[]))}")
PY
  # Kick Hermes immediately after enqueue (command-code sessions expect auto host-run).
  if [[ ${AEGL_DUAL_LINK_AUTO_CONTINUE:-1} != 0 ]]; then
    kick_continue_bg enqueue || true
  fi
}

write_job_plan(){
  local item_json=$1 out=$2
  python3 - "$item_json" "$out" <<'PY'
import json,sys
it=json.load(open(sys.argv[1]))
plan={
  "job_id": it["job_id"],
  "thread_id": "cursor-inbox",
  "worker_model": it.get("worker_model","deepseek/deepseek-v4.1-flash"),
  "max_actions": it.get("max_actions",3),
  "max_wall_seconds": it.get("max_wall_seconds",3600),
  "evidence": it["evidence"],
  "evidence_sha256": it["evidence_sha256"],
  "acceptance": it["acceptance"],
  "task": {
    "project": it.get("project","OfflineTaskCalendar_WPF"),
    "task_id": it["task_id"],
    "contract_package": f"/var/lib/aegl-model/trusted/OfflineTaskCalendar_WPF/reports/contracts/{it['task_id']}",
    "contract_manifest_sha256": it["manifest_sha256"],
    "max_runtime_s": it.get("max_runtime_s",300),
  },
}
open(sys.argv[2],"w").write(json.dumps(plan, ensure_ascii=False, indent=2)+"\n")
print(sys.argv[2])
PY
}

queue_len(){
  python3 - "$QUEUE_FILE" <<'PY'
import json,sys,os
qf=sys.argv[1]
if not os.path.exists(qf):
    print(0); raise SystemExit(0)
try: q=json.load(open(qf))
except Exception: print(0); raise SystemExit(0)
print(len(q.get("items") or []))
PY
}

run_one_queue_item(){
  # Pop one item → prepare → submit → host-run --auto-decide (does not exec).
  local item_file=$STATE_DIR/continue-item.json
  python3 - "$QUEUE_FILE" "$item_file" <<'PY' || return 2
import json,sys
qf, out = sys.argv[1], sys.argv[2]
q=json.load(open(qf))
items=q.get("items") or []
if not items: raise SystemExit(1)
it=items.pop(0)
q["items"]=items
open(qf,"w").write(json.dumps(q, ensure_ascii=False, indent=2)+"\n")
open(out,"w").write(json.dumps(it, ensure_ascii=False, indent=2)+"\n")
print(it["job_id"], it["task_id"])
PY

  local job_id task_id task_root base_commit manifest
  job_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["job_id"])' "$item_file")
  task_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["task_id"])' "$item_file")
  task_root=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["task_root"])' "$item_file")
  base_commit=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["base_commit"])' "$item_file")
  manifest=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["manifest_sha256"])' "$item_file")

  echo "CONTINUE job=$job_id task=$task_id root=$task_root"

  if ! prepare_nopasswd_ok; then
    python3 - "$QUEUE_FILE" "$item_file" <<'PY'
import json,sys
qf, itemf = sys.argv[1], sys.argv[2]
q=json.load(open(qf)) if __import__("os").path.exists(qf) else {"version":1,"items":[]}
it=json.load(open(itemf))
q.setdefault("items", []).insert(0, it)
open(qf,"w").write(json.dumps(q, ensure_ascii=False, indent=2)+"\n")
PY
    local msg="PREPARE_NOPASSWD_REQUIRED: bash $ROOT/install-nopasswd-prepare.sh  (one sudo password), then: $SELF continue"
    echo "$msg" | tee "$STATE_DIR/NEXT_ACTION.txt"
    printf '%s\n' "{\"kind\":\"PREPARE_NOPASSWD_REQUIRED\",\"written_at\":$(date +%s),\"hint\":\"bash $ROOT/install-nopasswd-prepare.sh && $SELF continue\"}" >"$INBOX/WAKE"
    die "$msg"
  fi

  echo "== prepare =="
  local prep_log=$STATE_DIR/prepare-$task_id.log
  if ! sudo -n "$PREPARE_BIN" --task "$task_id" "$task_root" "$base_commit" "$manifest" \
      >"$prep_log" 2>&1; then
    python3 - "$QUEUE_FILE" "$item_file" <<'PY'
import json,sys,os
qf, itemf = sys.argv[1], sys.argv[2]
q=json.load(open(qf)) if os.path.exists(qf) else {"version":1,"items":[]}
it=json.load(open(itemf))
q.setdefault("items", []).insert(0, it)
open(qf,"w").write(json.dumps(q, ensure_ascii=False, indent=2)+"\n")
PY
    tail -40 "$prep_log" >&2 || true
    die "prepare failed — see $prep_log (item restored to queue head)"
  fi
  grep -E 'REGISTER_OK|GATE_OK|PREP_COMPLETE|PREP_FAILED' "$prep_log" || true
  grep -q "PREP_COMPLETE task=$task_id" "$prep_log" || die "PREP_COMPLETE marker missing"

  local plan_path=$task_root/job-plan.json
  write_job_plan "$item_file" "$plan_path"
  echo "== submit =="
  "${PY[@]}" "$STACK_JOBS_PY" submit --plan "$plan_path" | tee "$STATE_DIR/submit-$job_id.json"
  local sha; sha=$(plan_sha "$job_id")
  echo "== host-run auto-decide job=$job_id sha=$sha =="
  env AEGL_DUAL_LINK_AUTO_DECIDE=1 \
    ${HERMES_CHATGPT_CONTROL_URL:+HERMES_CHATGPT_CONTROL_URL="$HERMES_CHATGPT_CONTROL_URL"} \
    "${PY[@]}" "$STACK_JOBS_PY" host-run \
    --job-id "$job_id" --thread-id cursor-inbox --plan-sha256 "$sha"
  local hr=$?
  local st
  st=$(job_status "$job_id" 2>/dev/null || echo '?')
  echo "HOST_RUN_EXIT job=$job_id exit=$hr status=$st"
  # host-run may exit 0 even on HUMAN_REQUIRED/STOP; treat non-COMPLETE as drain failure.
  if [[ $st != COMPLETE ]]; then
    echo "HOST_RUN_NOT_COMPLETE job=$job_id status=$st" >&2
    return 1
  fi
  return 0
}

cmd_continue(){
  # Drain queue: prepare→submit→host-run for each item. Stops on first hard failure.
  need python3
  [[ -f $QUEUE_FILE ]] || die "queue empty — enqueue a frozen item first"
  # shellcheck disable=SC1091
  [[ -f $STATE_DIR/last-env.sh ]] && . "$STATE_DIR/last-env.sh" || true
  export AEGL_DUAL_LINK_AUTO_DECIDE=${AEGL_DUAL_LINK_AUTO_DECIDE:-1}

  local n ran=0
  n=$(queue_len)
  [[ "$n" -gt 0 ]] || die "queue empty — enqueue a frozen item first"
  echo "QUEUE_DRAIN start len=$n"

  while [[ $(queue_len) -gt 0 ]]; do
    ran=$((ran+1))
    echo "QUEUE_DRAIN item=$ran remaining=$(( $(queue_len) ))"
    if ! run_one_queue_item; then
      echo "QUEUE_DRAIN_STOP after item=$ran (host-run/prepare failed)" | tee "$STATE_DIR/NEXT_ACTION.txt"
      return 1
    fi
  done

  echo "QUEUE_DRAIN_DONE ran=$ran queue_empty=1" | tee "$STATE_DIR/NEXT_ACTION.txt"
  printf '%s\n' "{\"kind\":\"QUEUE_EMPTY\",\"ran\":$ran,\"written_at\":$(date +%s),\"hint\":\"enqueue next frozen item then: $SELF continue\"}" >"$INBOX/WAKE"
}

usage(){
  cat <<EOF
Usage: $0 arm [--quiet] [--cwd DIR] [--session-up|--no-session-up]
       $0 session-up [DIR]
       $0 advise-post --cwd DIR (--text-file PATH | --stdin)
       $0 bind-control --cwd DIR --url https://chatgpt.com/c/<id> [--aegl-project NAME]
       $0 status | watch-inbox | host-run <JOB> | decide-hint <JOB>
       $0 enqueue <item.json> | continue
       $0 new-control [--forbid SUBSTR] [--bind-cwd DIR --aegl-project NAME]

Per-project ChatGPT: each coding root must be bound to its own conversation.
command-code → arm --session-up + onStop advise-post to Chrome ChatGPT.
enqueue / watcher also auto-continue (Hermes) when AEGL_DUAL_LINK_AUTO_CONTINUE=1.
host-run auto-decide execute→acceptance→COMPLETE (no Cursor pause).
continue needs NOPASSWD prepare: bash $ROOT/install-nopasswd-prepare.sh
new-control: IME-safe CDP create of a fresh https://chatgpt.com/c/<id> (optional bind).
EOF
}

cmd_advise_post(){
  need python3
  python3 "$ROOT/advise_post.py" "$@"
}

cmd_new_control(){
  # IME-safe fresh ChatGPT conversation for a project (never shares calendar by default).
  local forbid=6ac4d058 bind_cwd= aegl= note='dual-link new-control'
  while [[ $# -gt 0 ]]; do
    case $1 in
      --forbid|--forbid-substring) forbid=$2; shift 2 ;;
      --bind-cwd) bind_cwd=$2; shift 2 ;;
      --aegl-project) aegl=$2; shift 2 ;;
      --note) note=$2; shift 2 ;;
      *) die "unknown new-control arg: $1" ;;
    esac
  done
  need python3
  bash "$ROOT/ensure-cdp-control.sh" --restart >/dev/null 2>&1 || \
    python3 "$ROOT/cdp_chat.py" ensure-cdp --restart
  # Wait for login if needed — new-chat will fail clearly.
  local url
  url=$(python3 "$ROOT/cdp_chat.py" new-chat ${forbid:+--forbid-substring "$forbid"})
  echo "NEW_CONTROL_URL=$url"
  if [[ -n $bind_cwd ]]; then
    [[ -n $aegl ]] || die "new-control --bind-cwd requires --aegl-project"
    python3 "$ROOT/project_control.py" bind --cwd "$bind_cwd" --url "$url" \
      --aegl-project "$aegl" --note "$note"
    echo "BOUND cwd=$bind_cwd aegl_project=$aegl"
  fi
}

main(){
  local c=${1:-status}
  shift || true
  case $c in
    arm) cmd_arm "$@" ;;
    session-up) cmd_session_up "${1:-$PWD}" ;;
    advise-post) cmd_advise_post "$@" ;;
    bind-control) cmd_bind_control "$@" ;;
    new-control) cmd_new_control "$@" ;;
    status) cmd_status ;;
    watch-inbox) cmd_watch_inbox ;;
    host-run) cmd_host_run "${1:?job_id}" ;;
    decide-hint) cmd_decide_hint "${1:?job_id}" ;;
    enqueue) cmd_enqueue "${1:?item.json}" ;;
    continue|run-next) cmd_continue ;;
    -h|--help|help) usage ;;
    *) usage; exit 2 ;;
  esac
}
main "$@"
