# 更换自动化任务使用的模型 API

此入口配置 Hermes → 受信 model broker 的模型通道。Chrome 中的固定 ChatGPT
会话、任务契约、独立 UID 沙箱、工具 guard 和推广 broker 都继续使用原入口。
Command Code/Cursor 的交互登录不由此工具修改，也不要求它们与 broker 使用同一个 key。

支持 OpenAI Chat Completions 兼容协议；模型需要支持任务所需的工具调用。
仅有 Responses 或 Anthropic Messages 原生接口的服务，不能直接用此配置宣称兼容。

每个服务配置保存六项：协议、API base URL、模型 ID、凭据来源文件、文件中的变量名、
认证头名称。配置不保存 key 值。支持多个配置，操作者通过 `use` 选择活动配置。
地址、模型、认证头和凭据引用会一起原子切换，避免混用不同服务的设置。

## 日常使用

1. 在可信终端用编辑器管理自己的凭据文件。可以继续用已有 `.env`，也可以用
   `/home/zhong/.config/aegl/keys.env`。目录建议 `0700`，文件 `0600`。
   文件格式是 `变量名=实际key`。不要在聊天、命令行参数或源码里填写实际 key。
   工具不读取、复制或验证 key 内容；broker 在每次新任务启动时读取选定来源。

2. 保存服务配置。例如 MiMo（先把 `MIMO_MODEL_ID` 设为你账户实际可用的模型 ID）：

   ```bash
   sudo aegl-model-config save mimo \
     --base-url https://api.xiaomimimo.com/v1 \
     --model "${MIMO_MODEL_ID:?请先设置实际模型ID}" \
     --credential-source /home/zhong/.config/aegl/keys.env \
     --credential-env MIMO_API_KEY \
     --auth-header api-key
   ```

3. 切换并查看活动配置：

   ```bash
   sudo aegl-model-config use mimo
   aegl-model-config show
   aegl-model-config list
   ```

4. 从原任务入口发起下一个任务。已经运行的 broker 使用其启动时加载的配置与凭据，
   切换不会改变进行中的任务。ChatGPT 会话和协议序列不需要重置。

以后更换 key：在原凭据文件中更新对应变量；下一个任务重读，无需修改源码或重新安装。
更换模型或服务设置：重新 `save` 该配置，再 `use`。`save` 本身不改变活动配置。

## 三类服务及通用入口

| 配置名称示例 | Base URL | 模型 ID | 认证头 |
|---|---|---|---|
| `commandcode` | `https://api.commandcode.ai/provider/v1` | Command Code 账户支持的完整模型 ID | `Authorization` |
| `deepseek` | `https://api.deepseek.com/v1` | DeepSeek 官方账户提供的模型 ID | `Authorization` |
| `mimo` | `https://api.xiaomimimo.com/v1` | MiMo 账户提供的模型 ID | `api-key` 或 `Authorization` |
| 任意自定义名称 | 服务方给出的 HTTPS API base | 该服务要求的模型 ID | 支持 `Authorization`、`api-key`、`x-api-key` |

沿用相同的 `save` 参数，为各服务分别声明凭据文件与变量名。
Command Code 网关中的模型 ID 与直连服务的 ID 可能不同，请按对应服务填写。
不能把 `/chat/completions` 等完整操作路径当作 API base。

DeepSeek 的 Bearer 和兼容协议见 <https://api-docs.deepseek.com/>；MiMo 的兼容 API
及两种认证方式见 <https://mimo.mi.com/docs/api/text-generation/openai-api>。
接口信息核对日期：2026-10-29。这里只提供配置方法，不固定一个会过期的模型版本。

## 保持的边界

- `/etc/aegl/model/providers/*.json` 保存配置引用；`/etc/aegl/model/config` 保存当前活动路由
  及既有运行时路径。`save/use` 需要 root，`show/list/validate` 不调用模型。
- 沙箱里仍只有本地 broker 地址和占位 key，真实上游与 key 不写进 Hermes 配置。
- HTTPS 保持默认 SNI 和证书校验。provider 配置不能关闭 TLS 校验。
- 配额耗尽或认证失败时报告实际错误，由操作者选择另一配置，不自动使用其他付费账户。
- 新安装没有活动模型时会明确要求配置，不再悄悄回退到已超额的 DeepSeek。
- broker 保留原读取顺序：指定环境变量覆盖 → 配置引用的 dotenv 文件。
  不会为了统一 key 去覆盖 Command Code、Hermes 或其他服务的认证文件。

当前验证仅涵盖配置切换、本机真实 TLS 转发、认证头注入和 key 轮换。
新服务的真实模型与沙箱任务验收需要在操作者选择可用配置后单独执行一次。
