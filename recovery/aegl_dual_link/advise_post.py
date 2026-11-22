#!/usr/bin/env python3
"""Post a plain Command Code report to ChatGPT and queue the advisor reply for CC reinject.

Never sends HERMES_TASK_V1. Uses Stack chatgpt_adapter.send_once over CDP :9333.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
STATE = Path.home() / ".local/state/aegl-dual-link"
STACK_BRIDGE = Path("/var/tmp/IAP-CONTROL-DEV/stack/orchestration/hermes/bridge")
FORMAL_BRIDGE = Path(
    "/home/zhong/Projects/Google-Android-Agent-Development-Stack/orchestration/hermes/bridge"
)

CONTROL_BLOCK = re.compile(
    r"HERMES_TASK_V1|EXECUTE_CONTRACT|<<<END_HERMES|<<<HERMES",
    re.I,
)

FRICTION_LEDGER = Path("/home/zhong/Projects/SYSTEM-FRICTION.md")
NONE_FRICTION = re.compile(
    r"^(none|n/?a|无|无候选|没有|nil|-|—|－)?$",
    re.I,
)

# Table row: | 8 | SYSTEM-FRICTION 候选 | text |
_FRICTION_TABLE = re.compile(
    r"\|\s*8\s*\|\s*[^|]*?(?:SYSTEM-FRICTION|系统摩擦|摩擦候选)[^|]*\|\s*([^|\n]+)\s*\|",
    re.I,
)
# Inline: SYSTEM-FRICTION 候选: text  /  8) ...：text
_FRICTION_INLINE = re.compile(
    r"(?:SYSTEM-FRICTION\s*候选|系统摩擦(?:候选)?)\s*[:：|]\s*(.+)$",
    re.I | re.M,
)
_FRICTION_ITEM8 = re.compile(
    r"(?:^|\n)\s*8[).、]\s*(?:系统摩擦[^:\n]*[:：]\s*)?(.+)$",
    re.I,
)


def _load_adapter():
    for bridge in (STACK_BRIDGE, FORMAL_BRIDGE):
        if (bridge / "chatgpt_adapter.py").is_file():
            sys.path.insert(0, str(bridge))
            import chatgpt_adapter as adapter  # noqa: E402

            return adapter
    raise SystemExit("chatgpt_adapter.py not found under Stack bridge paths")


def _resolve_url(cwd: str | None) -> str:
    sys.path.insert(0, str(ROOT))
    from project_control import resolve_control_url

    return resolve_control_url(cwd=cwd or os.getcwd(), allow_env=False)


def _ensure_tab(cwd: str | None, url: str) -> None:
    import subprocess

    ensure = ROOT / "ensure-cdp-control.sh"
    if ensure.is_file():
        subprocess.run(
            ["bash", str(ensure), cwd or os.getcwd()],
            check=False,
            capture_output=True,
            text=True,
            timeout=60,
        )


def build_report(body: str, *, cwd: str, source: str) -> tuple[str, str]:
    body = body.strip()
    if not body:
        raise SystemExit("empty report")
    if CONTROL_BLOCK.search(body):
        raise SystemExit("REFUSED: report contains Hermes control block")
    digest = hashlib.sha256(body.encode("utf-8")).hexdigest()[:12]
    ident = f"CC-ADVISE-{digest}"
    report = (
        "【Command Code 开发汇报｜顾问链｜非控制协议】\n"
        f"id={ident}\n"
        f"source={source}\n"
        f"cwd={cwd}\n"
        f"written_at={time.strftime('%Y-%m-%dT%H:%M:%S%z')}\n\n"
        f"{body}\n\n"
        "—— 系统门禁短清单（每轮必含；未写视为缺口）——\n"
        "1) 正式 Projects/AEGL/Stack 树：未写入 / 仅 worktree？\n"
        "2) Hermes 任务信封 / 执行契约控制块：未发往 Chrome？\n"
        "3) ChatGPT control_url：未与其它 aegl_project 共用？\n"
        "4) 本轮 scope：未越出当轮禁止项？\n"
        "5) 改动文件清单 + 各文件大约行数（体量异常请标出）？\n"
        "6) 若触碰分层/边界：Core/Infra/App 或 Domain 规则结论？\n"
        "7) 测试/构建：命令 + PASS/FAIL 数字？\n"
        "8) 系统摩擦一行（非 none 将自动写入 Projects/SYSTEM-FRICTION.md）？\n\n"
        "请只分析并给出下一步开发指令（中文或英文均可）。\n"
        "禁止输出任何 Hermes 任务控制信封或协议控制块。\n"
        "不要改 task_id、路径、预算或要求晋升正式仓。\n"
        "业务指令与系统摩擦分开写；不要要求本轮顺手改 AEGL/Stack 正式树。\n"
    )
    # Only scan the CC body. The wrapper above is trusted template text and must
    # not contain CONTROL_BLOCK tokens (or it false-refuses every post).
    return report, ident


def extract_friction_candidate(body: str) -> str | None:
    """Return friction text from SYSTEM GATE REPORT item 8, or None if absent/none."""
    text = (body or "").strip()
    if not text:
        return None
    raw = ""
    m = _FRICTION_TABLE.search(text)
    if m:
        raw = m.group(1).strip()
    if not raw:
        m = _FRICTION_INLINE.search(text)
        if m:
            raw = m.group(1).strip()
    if not raw:
        # Prefer a GATE REPORT section if present
        gate = re.search(
            r"SYSTEM\s+GATE\s+REPORT(.+?)(?:\n#{1,3}\s|\n——|\Z)",
            text,
            re.I | re.S,
        )
        chunk = gate.group(1) if gate else text
        m = _FRICTION_ITEM8.search(chunk)
        if m:
            raw = m.group(1).strip()
    raw = re.sub(r"\s+", " ", raw).strip(" `*\"'")
    # Drop leading labels left in the cell
    raw = re.sub(
        r"^(?:SYSTEM-FRICTION\s*候选|系统摩擦(?:候选)?)\s*[:：]\s*",
        "",
        raw,
        flags=re.I,
    ).strip()
    if not raw or NONE_FRICTION.match(raw):
        return None
    # Keep one line, cap length for the markdown table cell
    if len(raw) > 160:
        raw = raw[:157] + "..."
    return raw


def _friction_already_open(ledger: str, friction: str) -> bool:
    needle = friction.casefold()
    for line in ledger.splitlines():
        if not line.startswith("|"):
            continue
        parts = [p.strip() for p in line.strip("|").split("|")]
        if len(parts) < 5:
            continue
        # date | source | friction | severity | status | note
        cell, status = parts[2], parts[4].casefold()
        if cell.casefold() != needle:
            continue
        if status in {"open", "mitigating", "ready", "pending"}:
            return True
    return False


def append_friction_ledger(
    friction: str,
    *,
    cwd: str,
    source: str,
    report_id: str = "",
    severity: str = "P2",
) -> str:
    """Append one open row to SYSTEM-FRICTION.md. Returns status token."""
    path = FRICTION_LEDGER
    if not path.is_file():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            "# System friction ledger\n\n"
            "业务开发中发现的**系统**缺口/摩擦。不要写进日历契约；攒一批后走 IAP → promote。\n\n"
            "| 日期 | 来源 | 摩擦 | 严重度 | 状态 | 备注 |\n"
            "|---|---|---|---|---|---|\n",
            encoding="utf-8",
        )
    existing = path.read_text(encoding="utf-8")
    if _friction_already_open(existing, friction):
        print(f"FRICTION_SKIP_DUP {friction}")
        return "skip_dup"

    day = time.strftime("%Y-%m-%d")
    proj = Path(cwd).name or "CC"
    src = f"{proj} CC 自动"
    note_bits = [f"auto from {source or 'advise_post'}"]
    if report_id:
        note_bits.append(report_id)
    note = "; ".join(note_bits)
    # Escape pipes in cells
    cell = friction.replace("|", "/")
    row = f"| {day} | {src} | {cell} | {severity} | open | {note} |\n"

    lines = existing.splitlines(keepends=True)
    sep_idx = next((i for i, l in enumerate(lines) if l.startswith("|---")), None)
    if sep_idx is None:
        if not existing.endswith("\n"):
            existing += "\n"
        path.write_text(existing + row, encoding="utf-8")
    else:
        lines.insert(sep_idx + 1, row)
        path.write_text("".join(lines), encoding="utf-8")

    STATE.mkdir(parents=True, exist_ok=True)
    audit = {
        "kind": "FRICTION_AUTO",
        "friction": friction,
        "cwd": os.path.abspath(cwd),
        "source": source,
        "report_id": report_id,
        "written_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }
    with (STATE / "friction-auto.jsonl").open("a", encoding="utf-8") as f:
        f.write(json.dumps(audit, ensure_ascii=False) + "\n")
    print(f"FRICTION_LOGGED {path} :: {friction}")
    return "logged"


def maybe_log_friction(body: str, *, cwd: str, source: str, report_id: str = "") -> None:
    cand = extract_friction_candidate(body)
    if not cand:
        print("FRICTION_NONE")
        return
    append_friction_ledger(cand, cwd=cwd, source=source, report_id=report_id)


def queue_pending(instruction: str, *, cwd: str, source: str, report_id: str = "") -> Path:
    """Write advisor instruction for Command Code reinject (onStop continue / transformInput)."""
    instruction = instruction.strip()
    if not instruction:
        raise SystemExit("empty instruction")
    if CONTROL_BLOCK.search(instruction):
        raise SystemExit("REFUSED: advisor reply contains Hermes control block")
    STATE.mkdir(parents=True, exist_ok=True)
    meta = {
        "kind": "CC_ADVISOR_INSTRUCTION",
        "cwd": os.path.abspath(cwd),
        "source": source,
        "report_id": report_id,
        "written_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "chars": len(instruction),
        "sha256": hashlib.sha256(instruction.encode("utf-8")).hexdigest(),
    }
    pending = STATE / "pending-cc-instruction.md"
    reply = STATE / "last-advise-reply.md"
    pending.write_text(instruction + "\n", encoding="utf-8")
    reply.write_text(instruction + "\n", encoding="utf-8")
    (STATE / "pending-cc-instruction.json").write_text(
        json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"ADVISE_PENDING {pending}")
    return pending


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--cwd", default=os.getcwd())
    ap.add_argument("--source", default="command-code")
    ap.add_argument("--text-file")
    ap.add_argument("--text")
    ap.add_argument("--stdin", action="store_true")
    ap.add_argument("--min-chars", type=int, default=80)
    ap.add_argument(
        "--wait-reply",
        type=int,
        default=180,
        help="seconds to wait for ChatGPT reply (0=send only)",
    )
    ap.add_argument(
        "--queue-only",
        action="store_true",
        help="do not call Chrome; queue --text as pending CC instruction",
    )
    args = ap.parse_args()

    if args.text is not None:
        body = args.text
    elif args.text_file:
        body = Path(args.text_file).read_text(encoding="utf-8")
    elif args.stdin:
        body = sys.stdin.read()
    else:
        raise SystemExit("need --text, --text-file, or --stdin")

    if args.queue_only:
        queue_pending(body, cwd=args.cwd, source=args.source or "manual-queue")
        return 0

    if len(body.strip()) < args.min_chars:
        print(f"SKIP_SHORT chars={len(body.strip())} min={args.min_chars}")
        return 0

    url = _resolve_url(args.cwd)
    os.environ["HERMES_CHATGPT_CONTROL_URL"] = url
    os.environ["BU_CDP_URL"] = "http://127.0.0.1:9333"
    os.environ.pop("BU_CDP_WS", None)
    _ensure_tab(args.cwd, url)

    report, ident = build_report(body, cwd=os.path.abspath(args.cwd), source=args.source)
    # Log friction as soon as the CC body is accepted (even if Chrome send fails later).
    maybe_log_friction(
        body, cwd=os.path.abspath(args.cwd), source=args.source, report_id=ident
    )
    adapter = _load_adapter()

    previous = adapter.read_latest_assistant().get("sha256")
    sent = adapter.send_once(report, ident, exact=False)
    status = sent.get("status")
    print(f"ADVISE_SEND status={status} id={ident} url={url}")
    if status not in {"CONFIRMED_SENT", "ALREADY_PRESENT"}:
        print(f"ADVISE_SEND_FAILED {sent}", file=sys.stderr)
        return 2

    if args.wait_reply <= 0:
        return 0

    resp = adapter.wait_for_new_assistant(previous, timeout=args.wait_reply)
    print(f"ADVISE_REPLY status={resp.get('status')} chars={len(resp.get('text') or '')}")
    if resp.get("status") != "NEW_ASSISTANT":
        print("ADVISE_REPLY_TIMEOUT", file=sys.stderr)
        return 3
    text = (resp.get("text") or "").strip()
    if not text:
        print("ADVISE_REPLY_EMPTY", file=sys.stderr)
        return 3
    queue_pending(text, cwd=args.cwd, source=args.source, report_id=ident)
    # stdout line for Command Code mod to parse
    print("ADVISE_INSTRUCTION_BEGIN")
    print(text)
    print("ADVISE_INSTRUCTION_END")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
