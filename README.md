# claude-mcp-dsh

让 Claude Code 通过 MCP 指挥 [DeepSeek Harness（dsh）](https://www.npmjs.com/package/@deepseek-ai/dsh) 里的便宜模型干活：Claude（高级模型）负责定方案、写任务单、监控和独立验收，dsh 里的模型（默认 Command Code 渠道的 DeepSeek V4.1 Flash）只负责在指定工作区里写代码。

```
Claude Code（指挥、验收）
   │  MCP stdio
   ▼
control-ds/mcp/cds-mcp.mjs        ← 零第三方依赖的 MCP 服务
   │  ACP（ndjson over stdio），常驻一个 dsh 进程
   ▼
dsh --profile acp --patch <overlay>  →  Command Code  →  deepseek/deepseek-v4.1-flash（可换）
   │  cwd = 工作区（建议每个需求一个 git worktree）
   ▼
模型在工作区里读写代码；对话原文记录在 %TEMP%\dsh-runs\acp-<会话>.jsonl
```

## 功能

MCP 工具（`control-ds` 服务）：

| 工具 | 作用 |
|---|---|
| `flash_start(workspace, mode, resume_session_id?, model?, reasoning_effort?)` | 启动或复用常驻 dsh 并新建/接回会话；`resume_session_id` 可填 `"last"` |
| `flash_send(text \| text_file, interrupt?, limits?)` | 派活，立即返回 |
| `flash_wait(seconds)` / `flash_status(tail, full_reply)` | 进度：最近工具调用、思考尾巴、上下文用量、步数、在跑的工具、回复 |
| `flash_cancel()` / `flash_shutdown()` | 取消当前一轮 / 结束进程（会话由 dsh 保存，可接回） |
| `flash_models(filter?)` / `flash_set_model(model?, reasoning_effort?)` | 查看可选模型 / 两轮之间换模型 |
| `flash_sessions(workspace?)` | 列出记录过的会话（Claude 重启后仍可找回） |

内置的约束：

- **模型校验，失败即关闭**：只允许 `allowedProviders` 里的渠道（默认只有 `commandcode`），每次启动或切换后核对当前模型，拿不到或不一致就关闭会话，什么也不发。
- **权限**：只允许 `workspace-write` / `read-only`，模型发出的提权请求一律自动拒绝。
- **资源**：同时只跑一个 dsh 进程；启动前检查空闲内存。
- **防白耗 token（不限时）**：一轮内模型步数超限、同一工具调用同样结果连续重复、上下文达到硬上限（赶在 dsh 自动压缩前）都会自动取消这一轮，会话和记忆保留。
- **打断安全**：`interrupt=true` 取消后 30 秒没停下就报错，不会叠两轮。
- **只读沙箱修复**：dsh 的只读令牌连 `%TEMP%` 都写不了，Windows PowerShell 5.1 因此进入受限语言模式、所有命令失败；只读模式下自动把 TEMP 指向一个专用的低完整性临时目录。
- **网页可见**：把 ACP 会话登记进 dsh 网页的工作区列表，可以在 dsh web 里查看过程（网页服务关着时登记，开着时等下次 `web.ps1 start`）。

完整规则、流程和踩坑记录见 [`control-ds/SKILL.md`](control-ds/SKILL.md) 和 [`control-ds/reference/lessons.md`](control-ds/reference/lessons.md)。`scripts/` 是 MCP 不可用时的 headless 备用流程（PowerShell）。

## 环境要求

- Windows（沙箱、PowerShell 脚本、路径都按 Windows 写的）
- Node.js 20+
- Claude Code
- dsh `0.2.0-rc.1`，以及 Command Code 插件 [`@mars-sea/dsh-commandcode-provider`](https://www.npmjs.com/package/@mars-sea/dsh-commandcode-provider)（已在 dsh 的 acp profile 中安装并配置好 API key）

## 安装

```powershell
# 1. 放到 Claude Code 的 skills 目录
git clone https://github.com/halfwaystudent/claude-mcp-dsh.git
Copy-Item -Recurse claude-mcp-dsh\control-ds "$env:USERPROFILE\.claude\skills\control-ds"

# 2. 生成本地配置（config.json 不进版本库），按需修改 projectRoot 等
Copy-Item "$env:USERPROFILE\.claude\skills\control-ds\config.example.json" "$env:USERPROFILE\.claude\skills\control-ds\config.json"

# 3. 固定安装 dsh（不依赖 npx 缓存）
npm install @deepseek-ai/dsh@0.2.0-rc.1 --prefix "$env:LOCALAPPDATA\dsh-runtime\0.2.0-rc.1"

# 4. 注册为用户级 MCP 服务
claude mcp add control-ds --scope user -- node "$env:USERPROFILE\.claude\skills\control-ds\mcp\cds-mcp.mjs"
```

然后在 Claude Code 里用 `/control-ds`，或直接让 Claude "派活给 flash"。

## 配置（`config.json`）

| 键 | 说明 |
|---|---|
| `dshVersion` / `dshRuntimeRoot` | 使用的 dsh 版本与固定安装位置 |
| `expectedProvider` / `expectedModel` | 默认模型 |
| `allowedProviders` | 允许的渠道白名单 |
| `projectRoot` | 你的项目根目录 |
| `minFreeGB` / `maxProcessGB` | 内存门槛 |
| `continueBelowTokens` / `hardLimitTokens` | 上下文提示换会话 / 硬上限 |
| `turnGuards` / `maxTurnGuards` | 每轮步数、重复次数的默认值与上限 |
| `readOnlyTempDir` | 只读模式使用的临时目录 |

## 说明

- 这是个人工作流工具，非 DeepSeek / Command Code / Anthropic 官方项目。
- 不包含任何密钥：API key 由 dsh 的凭据库管理，本项目只引用环境变量名 `COMMANDCODE_API_KEY`，从不读取或输出密钥。
