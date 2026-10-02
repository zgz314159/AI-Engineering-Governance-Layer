# AI Engineering Governance Layer

这是一个**独立治理层母项目**，用来验证下面 6 个组件能否形成闭环，而不依赖任何真实业务项目：

1. GitHub Spec Kit
2. Architecture Guard
3. RuleSync
4. Konsist
5. Detekt
6. Gradle + GitHub Actions CI

## 核心链路

`governance/policy.json` 是唯一治理源：

```text
governance/policy.json
        │
        ├──> fixture/.specify/memory/constitution.md
        ├──> fixture/.specify/memory/architecture_constitution.md
        │           └── Architecture Guard 按 Spec Kit adapter 读取
        │
        ├──> fixture/.rulesync/rules/00-governance.md
        │           └── RuleSync -> CLAUDE.md / AGENTS.md / Cursor rules
        │
        └──> fixture/src/test/.../GeneratedArchitectureTest.kt
                    └── Konsist 硬性架构检查

Kotlin source
   ├── Detekt
   └── JUnit/Konsist
        │
        └── Gradle qualityGate
                 │
                 └── GitHub Actions
```

## 为什么还要下载 6 个上游项目源码？

`bootstrap.ps1` 会把上游仓库作为 Git submodule 下载到 `upstream/` 并固定版本。
这样你既有源码可审计、可重建，又不会把这些工具源码混进未来的业务工程。

- Spec Kit：本方案直接从本地 submodule 通过 `uv run --project` 执行。
- Architecture Guard：从本地 submodule 构建，并以 Spec Kit `--dev` 扩展接入 fixture。
- RuleSync：从本地 submodule 用 pnpm 构建，随后直接执行其 `dist/cli/index.js`。
- Konsist / Detekt：保留同版本源码 submodule；fixture 通过 Maven/Gradle 使用对应发布制品，避免把其复杂构建逻辑耦合进治理层。
- Gradle Actions：保留 v6.x 源码 submodule；CI 可以使用本地 submodule 中的 `setup-gradle` action。

## 第一次运行（Windows / PowerShell 7）

在解压目录打开 PowerShell 7：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\bootstrap.ps1
```

`bootstrap.ps1` 会依次：

1. 检查 Git / Node / npm / Java / Python / uv
2. 初始化母仓库
3. 下载并锁定 6 个上游源码
4. 构建 Spec Kit / Architecture Guard / RuleSync 的本地运行环境
5. 初始化 `fixture/` 的 Spec Kit
6. 从本地 Architecture Guard 源码安装 Spec Kit 扩展
7. 根据 `governance/policy.json` 生成治理产物
8. 生成 Gradle Wrapper
9. 执行正向质量门测试
10. 故意制造架构违规，确认 Konsist 会阻断
11. 故意制造 Detekt 违规，确认 Detekt 会阻断
12. 输出 `reports/bootstrap-report.json`

## 成功标准

最后必须看到：

```text
POSITIVE GATE: PASS
NEGATIVE ARCHITECTURE TEST: PASS (violation correctly blocked)
NEGATIVE DETEKT TEST: PASS (violation correctly blocked)
GOVERNANCE LAYER: PASS
```

如果“故意违规”反而通过，整个 bootstrap 会报错——因为这说明护栏没有真正工作。

## 重要说明

Architecture Guard 是 AI/SDD 编排治理层，不是编译器。自动化测试能够确定：
- Spec Kit 扩展已注册；
- Architecture Guard adapter/命令已接入；
- 宪法路径与它的 Spec Kit adapter 一致；
- RuleSync、Konsist、Detekt、Gradle Gate 能形成确定性闭环。

真正执行 `/ag-governed-delivery`、`/ag-verify` 之类的**语义型 AI 工作流**需要再启动 Claude/Codex 等 Agent。`docs/AGENT-SMOKE-TEST.md` 给出了最后一项人工 Agent smoke test。
