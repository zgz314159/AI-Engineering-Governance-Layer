#!/usr/bin/env python3
"""Post a plain Command Code report to ChatGPT and queue the advisor reply for CC reinject.

Also auto-archives SYSTEM GATE REPORT → Projects/SYSTEM-GATE-LOG.md + gate-reports.jsonl,
and auto-appends SYSTEM-FRICTION.md from gate anomalies / pipeline failures (no human copy).

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

FRICTION_LEDGER = Path("/home/zhong/Projects/SYSTEM-FRICTION.md")
GATE_LOG_MD = Path("/home/zhong/Projects/SYSTEM-GATE-LOG.md")

CONTROL_BLOCK = re.compile(
    r"HERMES_TASK_V1|EXECUTE_CONTRACT|<<<END_HERMES|<<<HERMES",
    re.I,
)
NONE_FRICTION_EXACT = re.compile(
    r"^(none|n/?a|无|无候选|没有|无新增|没有新增|暂无|nil|-|—|－)?$",
    re.I,
)
# "无新增（沿用…）" / "none — keeping prior items" etc.
NONE_FRICTION_SOFT = re.compile(
    r"(无新增|没有新增|无新的?\s*摩擦|无候选|暂无摩擦|no\s*new\s*friction|"
    r"none\s*(\(|（|-|—|:|：))",
    re.I,
)
_GATE_ROW = re.compile(
    r"\|\s*([1-8])\s*\|\s*([^|\n]+?)\s*\|\s*([^|\n]+?)\s*\|",
)
_FRICTION_TABLE = re.compile(
    r"\|\s*8\s*\|\s*[^|]*?(?:SYSTEM-FRICTION|系统摩擦|摩擦候选)[^|]*\|\s*([^|\n]+)\s*\|",
    re.I,
)
_FRICTION_INLINE = re.compile(
    r"(?:SYSTEM-FRICTION\s*候选|系统摩擦(?:候选)?)\s*[:：|]\s*(.+)$",
    re.I | re.M,
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


def _clip(s: str, n: int = 160) -> str:
    s = re.sub(r"\s+", " ", (s or "").strip())
    return s if len(s) <= n else s[: n - 3] + "..."


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
        "—— 系统门禁短清单（每轮必含；未写视为缺口；台账由管道自动落盘）——\n"
        "1) 正式 Projects/AEGL/Stack 树：未写入 / 仅 worktree？\n"
        "2) Hermes 任务信封 / 执行契约控制块：未发往 Chrome？\n"
        "3) ChatGPT control_url：未与其它 aegl_project 共用？\n"
        "4) 本轮 scope：未越出当轮禁止项？\n"
        "5) 改动文件清单 + 各文件大约行数（体量异常请标出）？\n"
        "6) 若触碰分层/边界：Core/Infra/App 或 Domain 规则结论？\n"
        "7) 测试/构建：命令 + PASS/FAIL 数字？\n"
        "8) 系统摩擦（可选；异常门禁与管道失败会自动写入 SYSTEM-FRICTION.md）？\n\n"
        "请只分析并给出下一步开发指令（中文或英文均可）。\n"
        "禁止输出任何 Hermes 任务控制信封或协议控制块。\n"
        "不要改 task_id、路径、预算或要求晋升正式仓。\n"
        "业务指令与系统摩擦分开写；不要要求本轮顺手改 AEGL/Stack 正式树。\n"
    )
    return report, ident


def parse_gate_report(body: str) -> dict:
    """Extract SYSTEM GATE REPORT table rows 1–8 when present."""
    text = body or ""
    has = bool(re.search(r"SYSTEM\s+GATE\s+REPORT", text, re.I))
    items: dict[str, dict[str, str]] = {}
    for m in _GATE_ROW.finditer(text):
        num, label, value = m.group(1), m.group(2).strip(), m.group(3).strip()
        items[num] = {"label": label, "value": value}
    return {"has_gate": has or bool(items), "items": items}


def extract_friction_candidate(body: str) -> str | None:
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
        gate = parse_gate_report(text)
        if "8" in gate["items"]:
            raw = gate["items"]["8"]["value"]
    raw = _clip(raw, 160).strip(" `*\"'")
    raw = re.sub(
        r"^(?:SYSTEM-FRICTION\s*候选|系统摩擦(?:候选)?)\s*[:：]\s*",
        "",
        raw,
        flags=re.I,
    ).strip()
    if not raw or _is_none_friction(raw):
        return None
    return raw


def _is_none_friction(raw: str) -> bool:
    s = (raw or "").strip()
    if not s:
        return True
    if NONE_FRICTION_EXACT.match(s):
        return True
    # Leading "无新增…" counts as none even with trailing explanation.
    if re.match(r"^(none|n/?a|无新增|没有新增|无候选|暂无)\b", s, re.I):
        return True
    if NONE_FRICTION_SOFT.search(s) and not re.search(r"[①②③1-9]\s*[.、:：]", s):
        # Soft none, unless it also lists numbered new items (①/1.) after a none claim.
        return True
    return False


def _neg_ok(value: str, *, ok_words: tuple[str, ...], bad_words: tuple[str, ...]) -> str | None:
    """Return friction reason if value looks bad; None if ok/unknown-soft."""
    v = value.casefold()
    if any(b in v for b in bad_words):
        # Allow explicit denial like "未发送" / "否"
        if any(o in v for o in ok_words):
            return None
        return value
    return None


def derive_frictions(body: str, gate: dict) -> list[tuple[str, str]]:
    """Return list of (severity, friction_text) inferred from gate / body. No human needed."""
    out: list[tuple[str, str]] = []
    if not gate.get("has_gate") and not gate.get("items"):
        out.append(("P1", "本轮 CC 汇报缺少 SYSTEM GATE REPORT 门禁表"))
        return out

    items = gate.get("items") or {}

    def val(n: str) -> str:
        return (items.get(n) or {}).get("value") or ""

    # 1 formal tree
    v1 = val("1")
    if v1 and _neg_ok(
        v1,
        ok_words=("否", "未", "没有", "仅", "worktree", "业务", "no"),
        bad_words=("写入正式", "已写入", "正式树", "aegl", "stack", "projects/"),
    ):
        # only flag if clearly affirmative write without 否/未
        if re.search(r"(是|写入了|已写|修改了正式)", v1) and not re.search(
            r"(否|未|没有|仅)", v1
        ):
            out.append(("P0", f"门禁1异常：疑似写入正式树 — {_clip(v1, 100)}"))

    v2 = val("2")
    if v2 and re.search(r"(已发送|发送了|发出)", v2) and not re.search(
        r"(未|没有|否)", v2
    ):
        out.append(("P0", f"门禁2异常：Hermes/契约曾发往 Chrome — {_clip(v2, 100)}"))

    v3 = val("3")
    if v3 and re.search(r"(共用|复用|串用|共享)", v3) and not re.search(
        r"(未|没有|否)", v3
    ):
        out.append(("P1", f"门禁3异常：control_url 串用 — {_clip(v3, 100)}"))

    v4 = val("4")
    if v4 and re.search(r"(越出|越界|超 scope|触碰禁止)", v4, re.I) and not re.search(
        r"(未|没有|否|仅)", v4
    ):
        out.append(("P1", f"门禁4异常：scope — {_clip(v4, 100)}"))

    def denied(v: str) -> bool:
        return bool(re.search(r"(未|没有|无|否|不存在|未发现)", v))

    v5 = val("5")
    if v5 and re.search(r"(异常体量|过大|巨大|huge|abnormal)", v5, re.I) and not denied(v5):
        out.append(("P2", f"门禁5异常体量 — {_clip(v5, 100)}"))

    v6 = val("6")
    if v6 and re.search(r"(泄漏|越界|边界破坏|违规)", v6) and not denied(v6):
        out.append(("P1", f"门禁6异常：分层 — {_clip(v6, 100)}"))

    v7 = val("7")
    if v7 and re.search(r"\bFAIL\b|失败|error\s*[1-9]|错误\s*[1-9]", v7, re.I):
        if not re.search(r"0\s*error|0\s*错误|\bPASS\b", v7, re.I):
            out.append(("P1", f"门禁7异常：测试/构建 — {_clip(v7, 100)}"))

    cand8 = extract_friction_candidate(body)
    if cand8:
        out.append(("P2", cand8))

    return out


def _friction_already_open(ledger: str, friction: str) -> bool:
    needle = friction.casefold()
    for line in ledger.splitlines():
        if not line.startswith("|"):
            continue
        parts = [p.strip() for p in line.strip("|").split("|")]
        if len(parts) < 5:
            continue
        cell, status = parts[2], parts[4].casefold()
        if cell.casefold() == needle and status in {
            "open",
            "mitigating",
            "ready",
            "pending",
        }:
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
    path = FRICTION_LEDGER
    if not path.is_file():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            "# System friction ledger\n\n"
            "由 advise_post **自动**从门禁表/管道事件写入；不要手抄。攒一批后 IAP → promote。\n\n"
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
    src = f"{proj} 自动"
    note = "; ".join(
        x for x in (f"auto:{source or 'advise_post'}", report_id) if x
    )
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
    with (STATE / "friction-auto.jsonl").open("a", encoding="utf-8") as f:
        f.write(
            json.dumps(
                {
                    "kind": "FRICTION_AUTO",
                    "friction": friction,
                    "severity": severity,
                    "cwd": os.path.abspath(cwd),
                    "source": source,
                    "report_id": report_id,
                    "written_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                },
                ensure_ascii=False,
            )
            + "\n"
        )
    print(f"FRICTION_LOGGED {path} :: [{severity}] {friction}")
    return "logged"


def _ensure_gate_log_header(path: Path) -> None:
    if path.is_file():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "# System gate log\n\n"
        "每轮 Command Code 顾问汇报的门禁摘要，由 `advise_post` **自动追加**。"
        "原文仍在 `~/.local/state/aegl-dual-link/cc-advise-*.md`。\n\n",
        encoding="utf-8",
    )


def archive_gate_report(
    body: str,
    *,
    cwd: str,
    source: str,
    report_id: str,
    gate: dict,
    frictions: list[tuple[str, str]],
    pipeline: str = "ok",
) -> None:
    STATE.mkdir(parents=True, exist_ok=True)
    ts = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    items = gate.get("items") or {}
    record = {
        "kind": "GATE_REPORT",
        "report_id": report_id,
        "cwd": os.path.abspath(cwd),
        "source": source,
        "written_at": ts,
        "pipeline": pipeline,
        "has_gate": bool(gate.get("has_gate")),
        "items": items,
        "frictions": [{"severity": s, "text": t} for s, t in frictions],
        "body_sha12": hashlib.sha256(body.encode("utf-8")).hexdigest()[:12],
        "body_chars": len(body),
    }
    with (STATE / "gate-reports.jsonl").open("a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")

    _ensure_gate_log_header(GATE_LOG_MD)
    lines = [
        f"## {ts} | {report_id} | {Path(cwd).name}\n",
        f"- cwd: `{os.path.abspath(cwd)}`\n",
        f"- source: `{source}`\n",
        f"- pipeline: `{pipeline}`\n",
        f"- has_gate: `{bool(gate.get('has_gate'))}`\n",
    ]
    if items:
        lines.append("- gate:\n")
        for n in map(str, range(1, 9)):
            if n in items:
                lines.append(
                    f"  - {n}. {items[n]['label']}: {items[n]['value']}\n"
                )
    else:
        lines.append("- gate: _(missing)_\n")
    if frictions:
        lines.append("- frictions_auto:\n")
        for sev, text in frictions:
            lines.append(f"  - [{sev}] {text}\n")
    else:
        lines.append("- frictions_auto: none\n")
    # short business blurb
    summary = _clip(body.splitlines()[0] if body.strip() else "", 120)
    lines.append(f"- summary: {summary}\n")
    lines.append("\n")
    with GATE_LOG_MD.open("a", encoding="utf-8") as f:
        f.writelines(lines)
    print(f"GATE_ARCHIVED {GATE_LOG_MD} id={report_id}")


def auto_capture_report(
    body: str,
    *,
    cwd: str,
    source: str,
    report_id: str = "",
    pipeline: str = "ok",
) -> dict:
    """Always archive gate; auto-append friction for anomalies. Human never copies."""
    body = body or ""
    if not report_id:
        report_id = f"CC-ADVISE-{hashlib.sha256(body.encode('utf-8')).hexdigest()[:12]}"
    gate = parse_gate_report(body)
    frictions = derive_frictions(body, gate)
    # Explicit pipeline failures always become friction
    if pipeline.startswith(
        ("ADVISE_", "REFUSED", "PIPE", "HERMES_IN_BODY", "SEND_")
    ) or pipeline.endswith("_FAILED") or pipeline.endswith("_TIMEOUT"):
        frictions.append(("P0", f"顾问管道异常: {pipeline}"))
    archive_gate_report(
        body,
        cwd=cwd,
        source=source,
        report_id=report_id,
        gate=gate,
        frictions=frictions,
        pipeline=pipeline,
    )
    logged = []
    for sev, text in frictions:
        st = append_friction_ledger(
            text, cwd=cwd, source=source, report_id=report_id, severity=sev
        )
        logged.append({"severity": sev, "text": text, "status": st})
    if not frictions:
        print("FRICTION_NONE (auto: no anomalies)")
    return {"report_id": report_id, "gate": gate, "frictions": logged}


def log_pipeline_failure(
    reason: str,
    *,
    cwd: str,
    source: str,
    body: str = "",
    report_id: str = "",
) -> None:
    auto_capture_report(
        body or f"(pipeline failure: {reason})",
        cwd=cwd,
        source=source,
        report_id=report_id or f"PIPE-{int(time.time())}",
        pipeline=reason,
    )


def queue_pending(instruction: str, *, cwd: str, source: str, report_id: str = "") -> Path:
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
    # Archive advisor reply briefly
    with (STATE / "advisor-replies.jsonl").open("a", encoding="utf-8") as f:
        f.write(json.dumps(meta | {"preview": instruction[:240]}, ensure_ascii=False) + "\n")
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
    ap.add_argument(
        "--capture-only",
        action="store_true",
        help="only archive gate/friction from the report; no Chrome",
    )
    ap.add_argument(
        "--pipeline",
        default="ok",
        help="pipeline tag for capture-only / failure logging",
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

    if args.capture_only:
        auto_capture_report(
            body,
            cwd=os.path.abspath(args.cwd),
            source=args.source or "capture-only",
            pipeline=args.pipeline or "ok",
        )
        return 0

    if len(body.strip()) < args.min_chars:
        print(f"SKIP_SHORT chars={len(body.strip())} min={args.min_chars}")
        return 0

    cwd_abs = os.path.abspath(args.cwd)
    try:
        report, ident = build_report(body, cwd=cwd_abs, source=args.source)
    except SystemExit as e:
        msg = str(e)
        log_pipeline_failure(
            msg, cwd=cwd_abs, source=args.source, body=body
        )
        raise

    auto_capture_report(
        body, cwd=cwd_abs, source=args.source, report_id=ident, pipeline="ok"
    )

    url = _resolve_url(args.cwd)
    os.environ["HERMES_CHATGPT_CONTROL_URL"] = url
    os.environ["BU_CDP_URL"] = "http://127.0.0.1:9333"
    os.environ.pop("BU_CDP_WS", None)
    _ensure_tab(args.cwd, url)

    adapter = _load_adapter()
    previous = adapter.read_latest_assistant().get("sha256")
    sent = adapter.send_once(report, ident, exact=False)
    status = sent.get("status")
    print(f"ADVISE_SEND status={status} id={ident} url={url}")
    if status not in {"CONFIRMED_SENT", "ALREADY_PRESENT"}:
        log_pipeline_failure(
            f"ADVISE_SEND_FAILED:{status}",
            cwd=cwd_abs,
            source=args.source,
            body=body,
            report_id=ident,
        )
        print(f"ADVISE_SEND_FAILED {sent}", file=sys.stderr)
        return 2

    if args.wait_reply <= 0:
        return 0

    resp = adapter.wait_for_new_assistant(previous, timeout=args.wait_reply)
    print(f"ADVISE_REPLY status={resp.get('status')} chars={len(resp.get('text') or '')}")
    if resp.get("status") != "NEW_ASSISTANT":
        log_pipeline_failure(
            "ADVISE_REPLY_TIMEOUT",
            cwd=cwd_abs,
            source=args.source,
            body=body,
            report_id=ident,
        )
        print("ADVISE_REPLY_TIMEOUT", file=sys.stderr)
        return 3
    text = (resp.get("text") or "").strip()
    if not text:
        log_pipeline_failure(
            "ADVISE_REPLY_EMPTY",
            cwd=cwd_abs,
            source=args.source,
            body=body,
            report_id=ident,
        )
        print("ADVISE_REPLY_EMPTY", file=sys.stderr)
        return 3
    queue_pending(text, cwd=args.cwd, source=args.source, report_id=ident)
    print("ADVISE_INSTRUCTION_BEGIN")
    print(text)
    print("ADVISE_INSTRUCTION_END")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
