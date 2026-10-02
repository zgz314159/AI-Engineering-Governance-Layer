# Architecture Guard semantic Agent smoke test

自动 bootstrap 已经能验证“文件/扩展/硬质量门”的连接。
Architecture Guard 的 `ag-*` 工作流本质上由 AI coding agent 执行，所以最后还需要一次很小的 Agent smoke test。

在 `fixture/` 打开 Claude Code（或支持对应技能的 Agent），先确认能看到 Architecture Guard 的 `ag-*` 技能/命令，然后做一个**不改业务功能**的小实验：

1. 让 Agent 读取 `.specify/memory/constitution.md`。
2. 让 Agent 读取 `.specify/memory/architecture_constitution.md`。
3. 运行 Architecture Guard 的 implementation review / verify 能力。
4. 确认它把 `Domain -> Presentation` 识别为禁止依赖。
5. 不提交任何故意违规代码。

这一步验证的是“AI 编排语义”，而 `scripts/60-negative-test.ps1` 验证的是“即使 AI 判断失误，Konsist/Detekt/Gradle 仍会硬阻断”。
