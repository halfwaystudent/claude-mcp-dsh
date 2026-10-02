---
name: control-ds
description: 指挥并约束 DeepSeek Harness（dsh）里 Command Code 渠道的 DeepSeek V4.1 Flash 干活。当用户调用 /control-ds，或要求派活、续接、监控、中断、验收 dsh 里的 flash 时使用。Claude 是指挥和决策者：定方案、写任务单、派活、实时监控、独立验收；flash 只负责在指定工作区里实现。
---

# control-ds：指挥 dsh 里的 flash

你（Claude）是指挥家和决策者；flash（dsh headless 里的 `deepseek/deepseek-v4.1-flash`，Command Code 渠道，便宜）只负责在指定工作区里写代码。**你不写项目代码，也不信 flash 的自我汇报。**

脚本目录（下文用 `$CDS` 表示）：`%USERPROFILE%\.claude\skills\control-ds\scripts`。所有脚本都是 PowerShell，用 `& "$CDS\xxx.ps1" 参数` 调用；运行记录保存在 `%TEMP%\dsh-runs\`。

## 0. 开始前

1. **工作目录**：指挥应当在项目根目录（`config.json` 的 `projectRoot`，下文写作 `<projectRoot>`）下进行（这样项目的 CLAUDE.md、Comet 阶段守卫才会生效）。如果当前会话的目录不是 `<projectRoot>`，先告诉用户"建议在 <projectRoot> 里重新启动 claude 再调用 /control-ds"；用户坚持继续也可以，此时所有路径用绝对路径，Comet 命令带 `--project-root`。flash 自己的工作目录是 change 的工作区（例如 `<projectRoot>\.worktrees\<change>`），由 `-Workspace` 指定。
2. **换新的 Claude 窗口时恢复状态**：先运行 `& "$CDS\status.ps1" -All` 看所有 run，再 `comet native status --project-root <projectRoot> --json` 看 Comet 阶段，读 change 的 `DESIGN.md` 进度。状态都在文件里，不靠对话记忆。
3. 需求要先和用户定好并在 Comet 里确认，再派活。**派活前把每条新规则用 3 个具体例子推演一遍**，避免规格缺口。

## 1. 硬规则（任何时候都不能破）

**模型与启动**
- **模型**：默认 Command Code 的 `deepseek/deepseek-v4.1-flash`（`config.json` 的 `expectedProvider`/`expectedModel`），由 overlay 以 `--patch` 传入，不改用户配置。**用户指定时**可换成 dsh 提供的其他模型（`flash_models` 查看，`flash_start(model=…)` 或会话中 `flash_set_model`），但只允许 `allowedProviders` 里的渠道（默认只有 `commandcode`），每次选择后都核对当前模型，拿不到或不一致就关闭会话。**不要自作主张换模型**：换模型、改推理强度、往 `allowedProviders` 加渠道（尤其 `deepseek-official` 官方接口）都要用户明确同意。换模型后下一轮缓存全部失效；不同模型价格差很多，切换前告诉用户。
- **dsh 用固定安装**：`%LOCALAPPDATA%\dsh-runtime\<dshVersion>`（`config.json` 的 `dshRuntimeRoot` + `dshVersion`），MCP、`dispatch.ps1`、`preflight.ps1`、`web.ps1` 都从这里取，不再走 npx。只在 npx 缓存里找到时 preflight 报 WARN、`flash_start` 结果里带 `dsh.warning`。升级：先 `npm install @deepseek-ai/dsh@<新版本> --prefix "%LOCALAPPDATA%\dsh-runtime\<新版本>"`，确认插件兼容（`--dump-config` 无 skipping profile bundle），再改 `config.json` 的 `dshVersion`；旧版本目录保留以便回退。
- 任务文本一律放在 UTF-8 文件里，由 `dispatch.ps1` 经标准输入交给 dsh（多行参数会被截断）。
- 权限只用 `workspace-write`（写代码）或 `read-only`（分析）；**永远不用 `danger-full-access`**；不让 flash 申请提权。`read-only` 下 TEMP 自动指向 `config.readOnlyTempDir`，否则 PowerShell 命令全部失败（见 lessons.md）。
- 每次派活必须先过 `preflight.ps1`（`dispatch.ps1` 会自动跑）：启动器版本、默认模型、无被跳过的插件、空闲内存 ≥ 3GB、没有别的 flash 或重进程在跑、工作目录 ACL。失败就不启动，先解决。

**资源**
- 同一时间只允许一个重任务（flash 运行、测试、回测、审查员、验收脚本不同时开）。
- flash 单个进程峰值内存 ≤ 4GB；数据必须分块；DuckDB 设内存上限。这些必须写进每份任务单。
- 因内存不足被系统终止时，**不自动重启**：先查原因（内存占用、flash 在跑什么），告诉用户，让用户决定。

**安全与边界**
- 数据来源目录只读，不产生 `__pycache__`；flash 只能写自己的工作区；不改 `docs/comet/`、不运行 `comet native`、不 git commit。**Comet 状态只由你推进。**
- 禁止 flash 结束不是它自己启动的进程；不使用联网搜索工具；不读、不打印密钥文件；日志里的登录令牌一律打码。
- 需要改用户的东西（权限 ACL、网页服务重启、默认配置）先问用户；只结束你自己启动的进程，不关用户的窗口。

**验收**
- flash 的最终回复只是线索。必须自己重跑测试、重跑回测比哈希、抽样对照原始数据，并派独立审查员，通过后才提交给 Comet。

## 2. 标准流程

> **首选方式：MCP 工具（常驻 ACP 会话）**。已注册为用户级 MCP 服务 `control-ds`（`mcp\cds-mcp.mjs`），工具：
> - `flash_start(workspace, mode, resume_session_id?, model?, reasoning_effort?)`：启动或复用常驻 dsh（ACP，无窗口）；不传 `model` 用默认模型，接回会话时沿用该会话上次记录的模型；只接受允许的渠道并核对当前模型，**拿不到模型信息也拒绝**；`resume_session_id` 可填 `"last"`，接该工作区最近一次会话；
> - `flash_models(filter?)`：列出 dsh 提供的模型（`use` 字段就是可传入的写法：默认渠道直接写模型 id，其他渠道写 `渠道:模型`），标出当前、默认、是否允许；
> - `flash_set_model(model?, reasoning_effort?)`：两轮之间切换模型或推理强度（`""` 为默认，常见 `high`/`max`，可选值随模型不同），对话保留；
> - `flash_sessions(workspace?)`：列出 MCP 记录过的会话（登记在 `%TEMP%\dsh-runs\sessions.json`，Claude 重启后仍在），新窗口恢复时先查它；
> - `flash_send(text | text_file, interrupt?, limits?)`：派活或追加指示，立即返回；它在忙时要么等，要么 `interrupt=true` 先取消再发（30 秒内没停下就报错、不发，防止两轮叠在一起）。**不限时，只防白耗 token**（等命令、等回测不调用模型，不花钱）：每轮三道检查，触发即自动取消这一轮（会话和记忆保留，不杀进程）——① 步数：一轮内模型调用次数超过 `steps`（默认 400）；② 死循环：同一个工具调用、同样的结果连续 `repeats` 次（默认 5，比较时忽略 description 这类说明文字）；③ 上下文：任何一步达到 `hardLimitTokens`（78 万）立即取消，赶在 dsh 80 万自动压缩之前。默认值在 `config.json` 的 `turnGuards`，按任务用 `limits: {steps, repeats}` 覆盖（上限 `maxTurnGuards`）。`flash_status` 显示 `steps`、`contextSent`（本轮累计重发的上下文，费用大头）、`sameResultInARow`、`stoppedBy`；取消后 60 秒还没停下会标 `STUCK`，由你决定是否 `flash_shutdown`。长时间没动静不会自动处理，靠你看 `runningTools`（在跑什么、跑了几分钟）和 `idleSec` 判断。注意：flash 常把长命令放后台再用 `job_output` 等，取消只中止等待，后台命令（如回测 python）可能还在跑，取消后先查进程再决定；
> - `flash_wait(seconds≤110)` / `flash_status(tail, full_reply)`：进度、最近工具调用、思考尾巴、上下文用量、完整回复；
> - `flash_cancel()`、`flash_shutdown()`（会话由 dsh 保存，之后用 `resume_session_id` 接上）。
> 同一时间只有一个 dsh 进程；提权申请一律拒绝；上下文到 45 万提示换会话，到 78 万拒绝继续。对话原文记录在 `%TEMP%\dsh-runs\acp-<会话>.jsonl`。
> ACP 不报告缓存命中率，只报告上下文长度。
> **网页里查看 flash 会话**：ACP 会话本来就存在 `~/.dsh/sessions/<工作目录>/`，但网页只列出 `~/.dsh/storages/workspace.json` 里登记过的。网页服务**关着**时，`flash_start` 会把工作区和会话登记进去（首次改动前备份为 `workspace.json.bak-cds`）；网页**开着**时先记为待登记，`web.ps1 start` 启动前会补登记（也可手动 `node mcp\cds-mcp.mjs --sync-web`）。网页里看到的是打开时的快照，要刷新才更新；**flash 在跑的会话不要在网页里发消息**（两个进程同时写一个会话记录）。Command Code 额度看网页侧边栏的额度卡片（web 配置已开 `showSidebarQuota`），它是账号级的，和会话无关。
> MCP 不可用时，退回下面基于 headless 的脚本流程（2.1–2.4）。

### 2.1 写任务单
复制 `templates\task-sheet.md`（首次）或 `templates\resume-sheet.md`（新会话接手），填好后保存为 `%TEMP%\dsh-runs\<run-name>.task.txt`（UTF-8，用 Write 工具写）。范围用验收编号表示；写明"本轮不要做"和"已知规格问题"；工程约束一字不落地带上。

### 2.2 派活
```
& "$CDS\dispatch.ps1" -Workspace <工作区> -TaskFile <任务单> -Name <run名> [-Mode read-only]
```
- 新任务、新会话：直接派。
- **接着上一轮、上下文还够用：`-Continue <上一轮run名>`**。上一轮必须已经退出、工作区相同。上下文（最后一步的输入 + 缓存 token）低于 45 万才会续接；否则脚本拒绝并提示。此时用 `-AllowNewSession` 并把任务单写成自包含的续做单（`resume-sheet.md`）。dsh 在约 80 万时会自动压缩历史（丢细节、缓存失效一次），所以要在 78 万前换会话。flash 没有按长度分档的价格，但工作日北京时间 9–12 点、14–18 点单价翻倍，大任务尽量避开。
- 续接同一个会话时，flash 还记得之前的约束，但仍要把最关键的三条重复一遍（一次只跑一个进程、内存上限、不改 docs/comet）。
- 不要续接一个正在网页里打开的会话，也不要续接还在运行的会话。

### 2.3 监控
用 Monitor 工具启动（`timeout_ms` 用 1800000）：
```
powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.claude\skills\control-ds\scripts\watch.ps1" -Name <run名>
```
只推送：新增或修改的代码文件（每个文件只报一次）、真正的失败、上下文越过阈值、TURN_END、FINAL/ERROR、进程意外退出（PROCESS-EXITED）、长时间无事件（STALE）。监控到期就重新启动；run 结束后不留监控。随时用 `status.ps1 -Name <run名>` 主动查看进度、上下文、内存、失败。`cleanup.ps1` 清理残留的监控进程。

### 2.4 中断
```
& "$CDS\stop.ps1" -Name <run名> -Reason "<原因>"
```
只在没有重进程（python）运行的时刻中断；脚本会拒绝并说明，除非 `-Force`。只结束该 run 的进程树，网页服务和别的 run 不受影响。中断后写续做单，再派。

### 2.5 验收（不信 flash 的汇报）
1. 自己运行（串行，可用后台运行并读日志）：
```
& "$CDS\verify.ps1" -Workspace <工作区> -TestCommand "<python> -B -m pytest -q -p no:cacheprovider" -RunCommand "<python> -B -m <项目> run" -OutputDir reports -Runs 2 -ReadonlyCommand "..." -SampleCommand "..."
```
   它依次跑测试、完整回测两次、比对输出目录的 SHA-256、抽样核对、只读比对，并检查兄弟目录里有没有 `__pycache__`。
2. **独立审查默认由我（Claude）这边做**：用 Agent 工具启动只读审查员（`subagent_type: Plan`，`run_in_background: true`）。审查提示里必须写：只读、不要写任何文件、只用 `python -B -c` 内联查询数据；工作区、需求文件、要审查的验收编号、已经验证过的内容（不要重做）、已知规格缺口（不算缺陷）、输出结构（逐条 PASS/FAIL/PARTIAL 加证据、新问题清单、一句总体结论）。审查员和验收脚本不要同时跑（内存）。
3. flash 汇报的关键数字，用独立计算交叉验证。
4. 审查发现问题：先修，再复审，不带病提交。

### 2.6 交给 Comet
只有你能推进 Comet。审查通过后提交 builder-handoff（`review.reviewer_execution_ref` 用描述性标签，不要用内部代理编号），如实写明已知限制。需求变化只在验证阶段用 `--revise-requirements` 退回，改完 brief 重新整理摘要，**等用户明确确认后**才继续。

### 2.7 网页服务（和 flash 无关，但常要用）
```
& "$CDS\web.ps1" -Action start     # 隐藏窗口启动，打印带令牌的登录链接
& "$CDS\web.ps1" -Action status
& "$CDS\web.ps1" -Action stop      # 只结束自己启动的；用户自己启动的要先问用户，或加 -Force
```
- 隐藏窗口启动，不出现在任务栏，避免有人误按 Ctrl+C 或关掉窗口（网页服务曾两次莫名收到 Ctrl+C，来源不明）。
- 每次重启会换登录令牌，**旧链接立即失效**，要把新链接给用户。
- 浏览器第一次用带 `?token=` 的链接打开后会得到一个签名 cookie，之后同一浏览器直接开 `http://127.0.0.1:3080/` 即可（服务重启也不影响）；换浏览器/无痕窗口/清 cookie 才需要再用带令牌的链接（`web.ps1 -Action status` 查看）。
- 用户想在自己的终端里起网页服务时，用同一份固定安装：先 `node %USERPROFILE%\.claude\skills\control-ds\mcp\cds-mcp.mjs --sync-web`，再 `node "%LOCALAPPDATA%\dsh-runtime\<dshVersion>\node_modules\@deepseek-ai\dsh\lib\bin.js" web`。
- 3080 端口只能有一个网页服务。已经用 `web.ps1` 在后台起过时，用户再手动运行 `npx @deepseek-ai/dsh@... web` 会报 `EADDRINUSE 127.0.0.1:3080`；这时用 `web.ps1 -Action status` 把现有链接给用户，或者先 `stop` 再让用户自己起（用户自己起的服务不会经过 `--sync-web`，需要先手动跑一次）。
- 版本用 `config.json` 里的 `dshVersion`，和 flash 用的启动器保持一致（都是固定安装那一份）。
- 不要让 flash 去动网页服务，也不要续接一个正在网页里打开的会话。

## 3. 对用户汇报的原则
- 每次说明：做了什么、当前进度、有没有风险；用大白话。
- 如实说明：flash 卡住、被内存终止、走了官方接口、我自己的疏漏（如需求写得有缺口）。
- 不确定的推断要标明是推断。

## 4. 参考
- `reference\lessons.md`：踩坑清单，遇到奇怪现象先查它。
- `templates\task-sheet.md`、`templates\resume-sheet.md`：任务单模板。
- `config.json`：版本、模型、阈值（空闲内存、上下文上限）都在这里改，不要写死在脚本里。
