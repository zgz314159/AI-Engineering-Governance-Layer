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
        "8) 系统摩擦（可选一行）：记入 Projects/SYSTEM-FRICTION.md 的候选？\n\n"
        "请只分析并给出下一步开发指令（中文或英文均可）。\n"
        "禁止输出任何 Hermes 任务控制信封或协议控制块。\n"
        "不要改 task_id、路径、预算或要求晋升正式仓。\n"
        "业务指令与系统摩擦分开写；不要要求本轮顺手改 AEGL/Stack 正式树。\n"
    )
    # Only scan the CC body. The wrapper above is trusted template text and must
    # not contain CONTROL_BLOCK tokens (or it false-refuses every post).
    return report, ident


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
