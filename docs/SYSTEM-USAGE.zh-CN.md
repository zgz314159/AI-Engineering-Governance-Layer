# AEGL 中文操作说明

核对日期：2026-11-11。AEGL 是系统治理与受控执行层，图片分析工厂是业务案例。
整套系统另有 [Stack 仓库](https://github.com/zgz314159/Google-Android-Agent-Development-Stack)，
完整教程在该仓 `docs/SYSTEM-USAGE.zh-CN.md`；当前本机路径为
`/var/tmp/IAP-CONTROL-DEV/stack/docs/SYSTEM-USAGE.zh-CN.md`。

## 1. 四类入口不要混淆

| 入口 | 作用 | 是否会产生动作 |
|---|---|---|
| `bin/aegl` | 项目探测、治理 adapter、handoff／resume、可选 Beads | status／inspect 默认只读；attach／handoff／memory 写入要看各自语义 |
| `bin/aegl-task` + `bin/aegl-ai` | 较早的外部 worktree、离线 sandbox 工作流 | start 写 Git 元数据；verify 运行测试；不是在线模型执行入口 |
| `aegl-model-task` | 模型任务 registry 的 register／show／list | register 只允许 root，查询按实际文件权限 |
| 安装的 `run_registered_task` → `aegl-hermes-sandbox` | 注册任务的受控模型执行 | root 受信准备／降权／沙箱／broker，可能调用付费模型 |

Stack `bridge_cli.py` 再负责控制协议与结果回传。不要把 `aegl resume` 当作 Bridge
的 recover，也不要把 `aegl-ai --net cloud` 当作在线模型捷径：源码会明确拒绝它。

## 2. 普通用户先看什么

在 zhong 普通终端操作：

```bash
export PYTHONDONTWRITEBYTECODE=1
AEGL=/var/tmp/IAP-CONTROL-DEV/aegl
STACK=/var/tmp/IAP-CONTROL-DEV/stack
bash "$AEGL/bin/aegl" --help
bash "$AEGL/bin/aegl" version
PROJECTS_ROOT="$HOME/Projects" bash "$AEGL/bin/aegl-recovery" doctor
/usr/local/bin/aegl-model-config validate
/usr/local/lib/aegl-model-task/bin/aegl-model-task --help
```

以上命令本轮已核对：version 为 `1.4.0-dev`；doctor 的 required 缺失为 0、
Hermes pin MATCH；模型路由格式验证通过。它们不验证真实模型额度，也不证明
浏览器、任务执行或业务验收通过。本次 PATH 没有 `aegl`／`aegl-model-task`，
因此这里使用实际入口，不要求修改系统链接。

需要探测自己的**已批准外部项目副本**时：

```bash
# PROJECT_WORKTREE 必须是自己明确选择的项目目录；本例未执行。
bash "$AEGL/bin/aegl" inspect "$PROJECT_WORKTREE"
bash "$AEGL/bin/aegl" status --root "$PROJECT_WORKTREE" --json
bash "$AEGL/bin/aegl" resume --root "$PROJECT_WORKTREE" --json
```

inspect 不加 `--write`；handoff、attach、verify、memory setup 不属于这组状态查询。
`inspect` 对未实现的技术 adapter 会拒绝，不能因此声称该项目已接入治理。

当前 continuity 默认位置是
`~/.local/state/aegl/projects/<project-key>/continuity/`；Beads 默认数据位置是
`~/.local/share/aegl/projects/<project-key>/beads`。以
`core/continuity/paths.py` 为准；`.aegl/manifest.json` 等 adapter 治理覆盖层文件
与交接运行状态不是同一种东西。不要把新运行状态放回 Projects。

## 3. 已安装组件与源码的关系

- 模型入口及模块：`/usr/local/lib/aegl-model/`。
- 受控 wrapper：`/usr/local/lib/aegl-bridge/run_registered_task`。
- 模型任务 registry：`/var/lib/aegl-model/registry.json`。
- root 路由元数据：`/etc/aegl/model/config` 与 providers；保存 credential 引用，
  不是让 AI 查看凭据的入口。
- 沙箱运行身份是 `aegl-ai`；推广由独立 broker／promotion 身份处理。
- 正式源码位于 `/home/zhong/Projects`；开发和验证在批准的外部副本中。

本轮只读核对：安装的 launcher、model broker、wrapper 分别与已验收源码一致。
源码新 commit／GitHub push 不会自动覆盖安装目录，也不会自动推广正式仓。
不使用本地 origin 推送、普通 cp 或 chmod 绕过正式树的可信推广流程。

## 4. 模型路由与认证

无模型调用的检查使用 `/usr/local/bin/aegl-model-config validate`。
`show`／`list` 展示元数据；`save`／`use` 会改变 root 管理的配置，需要操作者
选择服务后按 [模型服务说明](MODEL-PROVIDERS.md) 进行。

不把 key 放入命令行，不读取、复制或输出 dotenv／Token／SSH 私钥。
不要把教程旧模型 ID 当作服务当前支持列表；服务选择与真实认证由操作者核实。
沙箱通过本地 broker 接收受限访问，不能把真实上游 key 直接塞给沙箱内 Hermes。

已有安装可保留现有路由。格式通过不等于认证／额度通过；没有显式执行授权，
不要用一次“模型 smoke”代替配置检查。

## 5. 新任务如何准备、执行、验收

完整流程与浏览器恢复见 Stack 中文教程。AEGL 这一侧的顺序是：

1. 控制器分配新的、未消费的任务身份和准确的项目绑定。
2. 正式源码只读；建立受控外部 worktree 与 scratch，核对 baseline 和所有权。
3. 项目拥有的作者输入由 Stack 编译为冻结契约；root 安装受信副本。
4. 通过安装的 registry CLI 登记，再做无模型 sandbox `--check` 和 live-state 核验。
5. 明确批准一次真实执行，经受控 wrapper 调用；不使用源码目录里的任意脚本
   取代已经核验、root 控制的执行入口。
6. 分别检查模型／任务退出、cleanup、send 和契约证据；缺项写 UNKNOWN。
7. 验收后的源码才进入可信推广；push 是源码上传，不是安装／推广。

登记命令的真实语法如下，**仅为受信控制器准备阶段的模板，本轮不执行**：

```text
/usr/local/lib/aegl-model-task/bin/aegl-model-task register \
  --task-id <本轮批准的新ID> --worktree <已批准worktree绝对路径> \
  --scratch <已批准scratch绝对路径> --project <正式项目绝对路径> \
  --contract-package <root控制的契约包绝对路径>
```

详细约束见 [任务登记说明](MODEL-TASK-REGISTRY.md)：重复 ID 会被拒绝；路径、
归属、root 受信父链和契约授权必须匹配，不通过就停，不能自动 chown 修输入。
已消费的 001–008 不再运行；本轮没有创建 009 或批准任何新的真实任务。

## 6. 首次安装与现有宿主的边界

本机已有 r10 隔离检查、四文件观测部署与 cleanup marker 修正的历史验收，保留
其结果，不因教程编写重新执行。008 历史 cleanup UNKNOWN 的整体失败也不回填。

另一台机器应从 Stack 教程的“首次安装”开始：先克隆源码、核对路径与锁、做
普通用户预演，再逐项准备 root 信任边界。`bootstrap.ps1` 是 Windows 治理 fixture
构建；它不是当前 Linux 受控模型系统的一键部署器。

现有 `recovery/install-model-broker.sh` 是基础安装路径，源码清单还没有包含
`tool_event_client.py` 和 `tool_observer_config.py`，而且沿用旧递归清理实现。
本轮没有运行它，也不把它直接推荐为新机器的全套安装方案。最新 observer 部署
源码在 `recovery/tool_obs_deploy/`，已有宿主的部署验收无需重开；跨机完整首次安装
仍需单独审查与 root 运行证明。

任何 preflight、pin、owner/mode、entry-bind 或推广门禁失败，都报告具体失败并
保留现场。不要删除未知路径、force/prune worktree、关闭 guard 或改批准模式。
