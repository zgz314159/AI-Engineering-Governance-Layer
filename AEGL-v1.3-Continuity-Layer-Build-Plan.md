# AEGL v1.3 Continuity Layer 构建方案

> 项目：AI Engineering Governance Layer（AEGL）  
> 目标版本：v1.3  
> 模块名称：AEGL Continuity Layer  
> 核心目标：让长上下文 AI 编程任务可以在不同 Agent / 不同会话之间快速、可靠地接力，而不是依赖旧会话本身。  
> 设计原则：**推进优先，验证适量；事实可机器读取，语义交接可由 AI 补充；绝不陷入“验证验证器”的循环。**

---

## 1. 为什么要做 Continuity Layer

AEGL v1.0 解决“AI 写出来的代码是否符合治理要求”。

AEGL v1.1 解决“AEGL 如何接入外部项目”。

AEGL v1.2 解决“Android 项目如何被 AEGL 治理”。

v1.3 要解决的是另一个独立问题：

```text
旧 Agent 会话
上下文越来越长
        ↓
模型开始遗忘 / 压缩 / 重复劳动
        ↓
不得不开新会话
        ↓
新 Agent 不知道：
- 当前做到哪一步
- 哪些已经验证过
- 哪些方案已经失败
- 下一步是什么
- 哪些事情绝对不要重做
```

因此需要：

```text
AEGL Continuity Layer
```

将“当前工程状态”和“接力所需语义”从 AI 会话中抽离出来，持久化到仓库中。

---

# 2. 总体设计原则

## 2.1 不把 Handoff 做成新的治理迷宫

Continuity Layer 不是再增加一层无限审计。

不采用这种模式：

```text
handoff
  ↓
验证 handoff
  ↓
验证 handoff 验证器
  ↓
审计验证过程
  ↓
再审计审计器
```

而采用：

```text
事实采集
   ↓
一次性生成快照
   ↓
新 Agent 恢复
   ↓
做一个轻量一致性检查
   ↓
继续工作
```

原则：

1. **Git / CI / Test / Version 等事实由机器直接采集。**
2. **Current Goal / Next Action / Failed Attempts 等语义由 Agent 写入。**
3. **Resume 时只做一次轻量一致性检查。**
4. **Audit 默认不作为硬 Gate。**
5. **Handoff 不能阻止项目推进。**
6. **Handoff 失败时允许降级为“读取仓库 + 报告 + Git 状态”恢复。**

---

# 3. 最终架构

```text
                 AEGL Continuity Layer
                          │
             ┌────────────┼────────────┐
             │            │            │
             ▼            ▼            ▼
      Deterministic     Semantic     Persistent
          State         Handoff       Memory
             │            │            │
       Git / CI /      Goal / Next     Beads
       Tests / Tag     Decision /      optional
       Version         Dead Ends
             │            │            │
             └────────────┼────────────┘
                          ▼
                    state.json
                          +
                    HANDOFF.md
                          +
                    history/
                          │
                          ▼
                    aegl resume
                          │
                     quick check
                          │
                          ▼
                      New Agent
```

---

# 4. 目录结构

建议在 AEGL 本身建立：

```text
.aegl/
└── continuity/
    ├── state.json
    ├── HANDOFF.md
    ├── NEXT-SESSION.md
    ├── events.jsonl
    ├── config.json
    └── history/
        ├── 2026-10-02T180000Z.json
        ├── 2026-10-02T180000Z.md
        ├── 2026-10-03T011500Z.json
        └── 2026-10-03T011500Z.md
```

说明：

### `state.json`

机器可读的当前状态。

这是 Continuity Layer 的主要事实源。

### `HANDOFF.md`

给新 Agent / 人阅读的交接摘要。

### `NEXT-SESSION.md`

非常短，只保留“下一会话开场必须知道的内容”。

### `events.jsonl`

追加式事件记录。

用于记录重要阶段变化，不记录每一次 shell 命令。

### `history/`

每次 handoff 产生一份不可变历史快照。

---

# 5. Source of Truth 设计

不采用“Markdown 就是真相”的方式。

采用：

```text
Repository Reality
    ↓
state.json
    ↓
HANDOFF.md
```

## 5.1 机器事实

由 AEGL 自动读取：

```text
Git branch
Git HEAD
Git dirty/clean
VERSION
Git tags
Latest commit
CI status
CI run ID
Current feature branch
Test results
QualityGate results
Target adapter
Current release
```

这些字段不让 AI 自由填写。

## 5.2 AI 语义

由 Agent 提供：

```text
currentGoal
currentTask
completed
inProgress
blocked
failedApproaches
importantDecisions
doNotRepeat
nextAction
knownRisks
openQuestions
```

这些内容本来就属于语义信息，不适合硬编码扫描。

---

# 6. state.json Schema

第一版不需要非常复杂。

建议：

```json
{
  "schemaVersion": 1,
  "project": {
    "name": "AI-Engineering-Governance-Layer",
    "version": "1.3.0-dev"
  },
  "repository": {
    "branch": "feat/continuity-layer",
    "head": "abc123",
    "dirty": false,
    "remote": "origin"
  },
  "ci": {
    "status": "success",
    "runId": "123456789",
    "checkedAt": "2026-10-02T18:00:00Z"
  },
  "phase": {
    "name": "Continuity Layer",
    "status": "in_progress"
  },
  "work": {
    "goal": "Implement session handoff and resume",
    "currentTask": "Add state snapshot generator",
    "completed": ["state schema", "git state collector"],
    "inProgress": ["handoff renderer"],
    "blocked": [],
    "failedApproaches": ["Do not store full command transcript"],
    "doNotRepeat": ["Do not rerun v1.2 release workflow"]
  },
  "next": {
    "action": "Implement aegl resume",
    "command": "./bin/aegl resume"
  }
}
```

---

# 7. HANDOFF.md 格式

自动生成：

```markdown
# AEGL Session Handoff

## Verified State

Version:
1.3.0-dev

Branch:
feat/continuity-layer

HEAD:
abc123

Working Tree:
clean

CI:
PASS

## Current Goal

Implement AEGL Continuity Layer.

## Completed

- state schema
- git state collector
- handoff renderer

## Current Work

Implement `aegl resume`.

## Decisions

- state.json is the machine-readable truth.
- HANDOFF.md is a projection, not canonical truth.
- Audit is informative, not a hard gate.

## Failed / Rejected Approaches

- Do not persist full terminal transcript.
- Do not require full repository rescan on every resume.

## Do Not Repeat

- Do not recreate v1.2 fixtures.
- Do not rerun completed release workflow.

## Next Action

Run:

./bin/aegl resume

Then continue implementing resume validation.

## Open Questions

- Whether Beads should become an optional v1.4 backend.
```

---

# 8. NEXT-SESSION.md

这个文件要非常短。

目标是：**新 Agent 30 秒内进入状态。**

示例：

```markdown
# Next Session

Project:
AEGL

Branch:
feat/continuity-layer

Goal:
Finish `aegl resume`.

Already done:
- state.json
- handoff renderer
- event log

Do not redo:
- v1.2 Android Adapter
- repository bootstrap
- release work

Next:
Implement and test `aegl resume`.

Read only if needed:
- .aegl/continuity/HANDOFF.md
- reports/V1.3-CONTINUITY-LAYER-REPORT.md
```

---

# 9. events.jsonl

不记录所有命令。

只记录有意义的阶段事件。

示例：

```jsonl
{"ts":"2026-10-02T18:00:00Z","type":"phase_started","phase":"continuity-layer"}
{"ts":"2026-10-02T18:15:00Z","type":"task_completed","task":"state-schema"}
{"ts":"2026-10-02T18:30:00Z","type":"decision","id":"D001","summary":"state.json is canonical"}
{"ts":"2026-10-02T18:45:00Z","type":"handoff_created","snapshot":"2026-10-02T184500Z"}
```

第一版只定义少量事件：

```text
phase_started
phase_completed
task_started
task_completed
decision
blocked
unblocked
handoff_created
resume_started
resume_completed
```

不要做复杂 Event Sourcing 平台。

---

# 10. CLI 设计

在现有：

```text
bin/aegl
```

新增：

```bash
aegl status

aegl handoff

aegl resume

aegl continuity history
```

以后可扩展：

```bash
aegl remember
aegl continuity audit
```

但 v1.3 不要求全部实现。

---

# 11. `aegl status`

目的：快速生成当前工程事实。

执行：

```bash
aegl status
```

输出：

```text
AEGL Project Status
-------------------
Version: 1.3.0-dev
Branch: feat/continuity-layer
HEAD: abc123
Working Tree: clean
CI: success
Current Phase: Continuity Layer
Handoff: present
Handoff age: 28 minutes
```

---

# 12. `aegl handoff`

核心命令。

执行：

```bash
aegl handoff
```

流程：

```text
Collect deterministic state
        ↓
Read current semantic work state
        ↓
Write state.json
        ↓
Append important event
        ↓
Generate HANDOFF.md
        ↓
Generate NEXT-SESSION.md
        ↓
Copy immutable snapshot to history/
```

输出：

```text
AEGL Handoff
------------
State captured: PASS
Git state: PASS
CI state: PASS
HANDOFF.md: written
NEXT-SESSION.md: written
History snapshot: written

Next session can start with:
aegl resume
```

---

# 13. Agent 如何提供语义信息

不要求用户填写复杂表格。

支持：

```bash
aegl handoff \
  --goal "Finish Android module graph" \
  --next "Implement invalid dependency detection"
```

也允许 Agent 自动生成：

```text
.aegl/continuity/work.json
```

然后：

```bash
aegl handoff
```

只负责合并机器事实。

---

# 14. `aegl resume`

新会话第一条建议命令：

```bash
aegl resume
```

流程：

```text
Read state.json
      ↓
Read current Git state
      ↓
Compare branch / HEAD / working tree / version
      ↓
Check handoff age
      ↓
Print resume brief
```

只检查最关键字段。

---

# 15. Resume 验证不要过度

只验证：

```text
branch
HEAD
working tree
version
```

CI 状态只显示，不作为 resume 的硬阻塞条件。

示例：

```text
AEGL Resume
-----------
Recorded branch: feat/continuity-layer
Current branch: feat/continuity-layer
PASS

Recorded HEAD: abc123
Current HEAD: abc123
PASS

Working tree: clean
PASS

HANDOFF STATUS: VALID
```

如果 HEAD 不同：

```text
HANDOFF STATUS: STALE
Repository changed since handoff.
Recorded: abc123
Current: def456
Recommendation: inspect the new commits before continuing.
```

注意：**STALE 不代表禁止工作。** 它只是警告。

---

# 16. 新 Agent 开场体验

未来 DeepSeek / Claude / Codex 新会话只需要：

```text
项目：
/mnt/AndroidDev/Projects/AI-Engineering-Governance-Layer

先执行：
./bin/aegl resume

根据输出和：
.aegl/continuity/NEXT-SESSION.md

继续当前任务。
不要重新执行已完成阶段。
```

从几千字施工指令变成几十字。

---

# 17. Handoff History

每次：

```bash
aegl handoff
```

自动产生：

```text
.aegl/continuity/history/
20261002T180000Z.json
20261002T180000Z.md
```

允许：

```bash
aegl continuity history
```

第一版不用做复杂时间旅行。

---

# 18. Beads 集成方案

v1.3 不把 Beads 设为强依赖。

设计一个接口：

```text
PersistentMemoryBackend
```

默认：

```text
none
```

未来：

```text
beads
```

结构：

```text
AEGL Continuity
        │
        ├── Local Snapshot
        │
        └── Persistent Memory Adapter
                    │
                  Beads
```

v1.3 只预留接口。

v1.4 再真正实现：

```text
adapters/memory/beads/
```

避免 v1.3 scope 膨胀。

---

# 19. 第三方项目借鉴原则

AEGL 不直接复制第三方完整实现。

借鉴：

- **Beads**：长期任务图、依赖、阻塞、Agent persistent memory。
- **OpenGrove Handoff**：Agent-independent portable handoff。
- **session-handoff**：handoff → resume → feedback。
- **热/冷上下文分层**：`NEXT-SESSION.md` = hot，`HANDOFF.md` = warm，`history/` = cold。

v1.3 不做复杂评分系统。

---

# 20. Context Budget

新 Agent 不应该一开始读几十个文件。

推荐加载顺序：

```text
Level 1  NEXT-SESSION.md
Level 2  HANDOFF.md
Level 3  state.json
Level 4  history/
Level 5  Beads（未来）
```

这样可以显著降低 token 消耗。

---

# 21. Audit 设计

这里明确避免陷入审计循环。

v1.3：

```text
NO mandatory handoff audit
```

只提供简单：

```bash
aegl continuity check
```

检查：

```text
JSON schema valid
referenced files exist
HEAD format valid
timestamps valid
```

不判断：

```text
“AI 的总结是不是足够优秀”
```

这种不可确定问题。

---

# 22. Handoff Audit 放到未来可选功能

未来可增加：

```bash
aegl continuity audit
```

但只作为 diagnostic，不是 release gate。

它可以报告：

```text
Repeated completed task: 1
Repeated failed approach: 0
Unnecessary files re-read: 4
```

但不会阻止继续开发。

---

# 23. 不允许的方向

v1.3 不做：

```text
完整聊天历史存储
终端每条命令录像
Agent 全行为监控
全自动语义正确性评分
无限审计
Handoff 必须经第二个 AI 审批
Handoff 的 Handoff
复杂知识图谱
Vector DB
RAG
Multi-Agent scheduler
```

这些都不是本阶段目标。

---

# 24. MVP 范围

v1.3 必须只完成：

```text
state.json
HANDOFF.md
NEXT-SESSION.md
events.jsonl
history/
aegl status
aegl handoff
aegl resume
aegl continuity history
基础 schema validation
```

够了。

---

# 25. 实现结构

建议：

```text
core/
├── aegl.py
└── continuity/
    ├── __init__.py
    ├── collector.py
    ├── state.py
    ├── renderer.py
    ├── resume.py
    ├── history.py
    └── events.py
```

---

# 26. 各模块职责

### `collector.py`

负责确定性事实：Git、VERSION、CI、working tree、tags、branch、HEAD。

### `state.py`

负责 schema、read、write、atomic replace。

推荐：`write temp → fsync → rename`。

### `renderer.py`

负责 `state.json + semantic work state → HANDOFF.md + NEXT-SESSION.md`。

Markdown 不是 canonical storage。

### `events.py`

简单 JSONL append，不建立数据库。

### `resume.py`

只做 snapshot load、current state collect、diff、brief render。

### `history.py`

只做 snapshot save 和 snapshot list；第一版不支持复杂 rollback。

---

# 27. 测试 Fixtures

新增：

```text
fixtures/continuity/
├── clean-project
├── changed-head
├── dirty-project
└── stale-handoff
```

---

# 28. 正向测试

## Test 1

```text
clean repo
↓
aegl handoff
↓
state.json exists
HANDOFF.md exists
NEXT-SESSION.md exists
history exists
```

PASS。

## Test 2

```text
same repo
↓
aegl resume
```

必须：

```text
HANDOFF VALID
```

---

# 29. 负向测试

## Changed HEAD

handoff 后产生 new commit，再运行：

```bash
aegl resume
```

必须：

```text
HANDOFF STALE
```

但 exit code 不必失败，因为这是 warning。

## Dirty repo

handoff 记录 clean，然后修改文件。

resume 输出：

```text
Recorded clean
Current dirty
WARNING
```

---

# 30. 关键测试：禁止重复执行

建立一个模拟 handoff：

```text
completed:
- setup gradle

doNotRepeat:
- setup gradle
```

resume 输出必须明确：

```text
DO NOT REPEAT:
setup gradle
```

不需要做复杂 AI 行为监控。

---

# 31. CI

新增：

```text
continuity-smoke
```

至少测试：

```text
handoff generation
resume valid
resume stale
history snapshot
state schema
NEXT-SESSION render
```

原有治理、bootstrap、target adapter、Android adapter 等 Job 不得删除。

---

# 32. 性能目标

Continuity 命令必须快。

目标：

```text
aegl status   < 2 秒
aegl resume   < 2 秒
aegl handoff  < 5 秒
```

不应触发：

```text
完整 Gradle build
完整 bootstrap
全仓库 AI analysis
```

Handoff 是接力工具，不是 CI。

---

# 33. Handoff 什么时候生成

推荐：

```text
手动：aegl handoff
Agent 即将 /clear / new session / compact / 停止任务
阶段完成时可选自动生成
```

第一版不要 hook 所有 shell 退出。

---

# 34. 可选 Agent Hooks

未来可以支持：

```text
Claude Code hook
Codex hook
Cursor hook
OpenCode hook
```

实现 session ending → `aegl handoff`。

但不是 v1.3 release blocker。

---

# 35. 安全

Handoff 默认禁止写入：

```text
API Key
Token
password
.env values
private key
auth headers
```

生成前做简单 secret redaction：

```text
*_TOKEN
*_KEY
Authorization:
Bearer
```

但不做复杂 DLP 平台。

---

# 36. Path Redaction

项目根路径可以保留；用户 home 中无必要的绝对路径可归一化成 `$HOME/...`。

---

# 37. Git 策略

建议提交：

```text
schema
templates
config
code
HANDOFF.md
state.json
```

建议默认不提交高频：

```text
history/
```

避免 Git 噪音。

---

# 38. Snapshot 保留策略

默认：

```text
最近 20 份
```

或 30 天。

达到上限删除最旧本地 snapshot。

---

# 39. 配置文件

`.aegl/continuity/config.json` 示例：

```json
{
  "historyLimit": 20,
  "commitCurrentState": true,
  "commitHistory": false,
  "includeCi": true,
  "redactSecrets": true,
  "memoryBackend": "none"
}
```

---

# 40. v1.3 开发流程

```text
Phase 1  Schema + collector
Phase 2  handoff
Phase 3  resume
Phase 4  history + events
Phase 5  CI tests
Phase 6  feature branch green
Phase 7  release
```

Feature branch：

```bash
git switch main
git pull --ff-only
git switch -c feat/continuity-layer
```

---

# 41. 完成标准

以下全部通过即可完成 v1.3：

```text
aegl status                  PASS
aegl handoff                 PASS
state.json                   PASS
HANDOFF.md                   PASS
NEXT-SESSION.md              PASS
events.jsonl                 PASS
history snapshot             PASS
aegl resume valid            PASS
aegl resume stale            PASS
secret redaction             PASS
continuity-smoke CI          PASS
existing regression          PASS
```

不要求：

```text
Beads
semantic audit
multi-agent memory
RAG
vector database
```

---

# 42. v1.4 再考虑 Beads

v1.4：

```text
AEGL Persistent Memory
```

引入：

```text
PersistentMemoryBackend
```

支持：

```text
none
beads
```

让 `aegl remember / ready / task` 等能力映射到 Beads。

---

# 43. 最终路线

```text
AEGL v1.0  Governance Core                   ✅
AEGL v1.1  Target Adapter                    ✅
AEGL v1.2  Android Adapter                   当前
AEGL v1.3  Continuity Layer
            ├─ status
            ├─ handoff
            ├─ resume
            ├─ history
            └─ event log
AEGL v1.4  Persistent Work Memory
            └─ Beads Adapter
AEGL v1.5  Multi-Agent Coordination
```

---

# 44. 一句话定义

AEGL Continuity Layer 的定位不是：

> “保存 AI 聊天记录。”

而是：

> **将当前工程真实状态 + 当前工作语义压缩成一个可恢复的 Agent 接力点。**

最终：

```text
旧 DeepSeek
       ↓
aegl handoff
       ↓
关闭会话

新 DeepSeek
       ↓
aegl resume
       ↓
10~30 秒恢复状态
       ↓
继续工作
```

---

# 45. 核心取舍

这套方案刻意选择：

```text
推进速度
>
过度审计

确定性事实
>
AI 自我声明

简单文件
>
复杂数据库

轻量恢复检查
>
完整重新验证

可选第三方后端
>
核心强耦合

实际可用
>
理论完美
```

这就是 AEGL v1.3 Continuity Layer 应该坚持的方向。
