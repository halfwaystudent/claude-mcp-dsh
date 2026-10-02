# control-ds 踩坑清单（来自 2026-09 的实战，每条都真实发生过）

## 版本与模型
- **插件与启动器版本不兼容时，插件被静默跳过**，模型回退到 DeepSeek 官方 `deepseek-flash`（走官方 API，费用和渠道都变了）。`preflight.ps1` 用 `--dump-config` 检查：没有 “skipping profile bundle”，且默认模型是 `commandcode / deepseek/deepseek-v4.1-flash`。
- dsh 0.2.0 升级时把旧的 `~/.dsh/settings.yaml` 改名成 `settings.yaml.imported`，设置被导入到 **web** 配置；**headless 配置里的补丁是空的**，所以每次运行都必须带 `--patch cc-flash-overlay.yml` 指定模型。
- 配置里另有一处 `searchProvider: deepseek-official`：flash 一旦调用联网搜索就走官方接口。任务单里禁止使用联网搜索。
- **定价（插件内置价格表，美元/百万 token）**：v4.1 flash 平时 输入 0.15 / 输出 0.6 / 缓存读取 0.003（缓存约为未命中输入的 1/50）；**没有按上下文长度分档**，而是**工作日高峰时段全部翻倍**：UTC 01–04、06–10，即北京时间工作日 9:00–12:00、14:00–18:00，周末不算。大任务尽量避开高峰。（曾误把另一个模型的“27.2 万后翻倍”当成 flash 的，已更正。）
- **自动压缩**：dsh 压缩插件在上下文超过 min(窗口×0.8，窗口−预留输出131072−余量65536) 时触发，压缩后保留约 16%。按 100 万窗口约为 **80 万** 触发、保留约 14 万。压缩会丢细节并让缓存失效一次，所以在它之前主动换会话：续接上限 `continueBelowTokens`=45 万，硬上限 `hardLimitTokens`=78 万。
- **缓存**：一次任务内部命中率实测 97%–99.8%；只有新会话的第一步不命中（换模型、渠道、dsh 版本、工作目录、技能或 AGENTS.md 都会让开头变化）。成本大头是“上下文长度 × 步数”，所以要禁止 flash 用“睡几分钟再看”的方式轮询，减少碎步。

## 启动与任务文本
- 早期 dsh 从 npx 临时缓存（`npm-cache\_npx\<随机目录>`）加载，缓存一清就整套失效；2026-10-01 起改为固定安装 `%LOCALAPPDATA%\dsh-runtime\<版本>`，npx 缓存只做后备。
- ACP 会话存在 `~/.dsh/sessions/<工作目录>/`，但网页只显示 `storages/workspace.json` 里登记过的；网页服务运行时会把该文件放在内存里并覆盖外部改动，只能在它停着时登记（`--sync-web`）。
- 多行任务文本作为命令行参数会被 `.cmd` 外壳在第一行截断。**一律用标准输入**（`-` 加 `-RedirectStandardInput` 文件）。
- `.ps1` 脚本必须只含 ASCII：PowerShell 5.1 把无 BOM 的文件当 GBK 读，中文会吞掉引号导致脚本莫名报错。中文放在单独的 UTF-8 文本文件里。
- PowerShell 里 `>` 和 `*>` 重定向写出 UTF-16，读取工具会把它当二进制文件。让程序自己写文件，或用 `Out-File -Encoding utf8`。
- 命令行里的带引号内联 Python 会被 PowerShell 弄坏，一律写成脚本文件。
- `Start-Process` 启动的进程独立于 Claude 会话，不会被“后台任务内存保护”终止，也不会有完成通知，所以要用 `watch.ps1` 监控进程退出。

## 权限与沙箱
- **只读模式下 PowerShell 命令全部失败**（2026-10-02 查明并修复）：dsh 的只读令牌哪里都不能写，包括 `%TEMP%`；Windows PowerShell 5.1 启动时要往 TEMP 写测试脚本判断有没有 AppLocker，写不进去就进入 ConstrainedLanguage，dsh 每条命令开头的编码设置因此报"语言模式不支持方法调用"。修复：只读模式启动 dsh 时把 TEMP/TMP 指向 `config.readOnlyTempDir`（Everyone 可修改 + Low 完整性标签），MCP 和 `dispatch.ps1` 自动设置。代价：只读的 flash 能在这个临时目录里写临时文件，项目和其他目录仍然写不了（实测）。修复前用 `read-only` 派的、需要跑命令的分析任务，命令其实都失败了。
- dsh 0.2 沙箱要求你的账户对工作目录有**显式的完全控制**权限，否则每条命令都报 `SetNamedSecurityInfoW failed (Win32 5)`（0.1.5 会静默跳过隔离，所以以前没发现）。
- 沙箱会给工作目录树留下永久的低完整性标签，并且只有第一次授权时会遍历整棵树（大目录可能要几十秒到几分钟）。不要在数据目录很大的根目录上首次运行，用较小的工作区。
- 无人审批时，申请提权的命令直接失败，不会挂起；flash 无法删除工作区以外的文件，残留物（例如 `__pycache__`）由协调者清理。

## 资源
- 这台机器 15.7GB 内存，常驻程序占约 9GB。flash 一次性把全历史面板读进内存，或并行跑两次回测，都会触发系统内存保护，任务被终止（`killed because the system is running low on memory`）。被终止后**不要自动重启**，先查原因、告诉用户。
- 分块读取加 4GB 单进程上限之后，完整回测约 16 分钟、峰值约 3GB。

## 监控
- 事件里的常见小麻烦不是失败：`old_string was not found / matched`、`file changed since it was read`、`cannot read ... binary file`、读取不存在的文件。`watch.ps1` 已过滤。
- flash 用睡眠等待长任务时，任务崩了它也不知道，会白等。`watch.ps1` 检测进程退出，并对长时间无事件给出 STALE 提示。
- 监控用的 `tail -f` 进程要及时清理（`cleanup.ps1`）。

## 中断与续接
- 只在没有重进程（python）运行的时刻中断；只结束该 run 的进程树（`taskkill /T`），不动网页服务和别的 run。
- `--session-id` 续接：同一工作目录、上一个 run 已退出、会话没在网页里打开；找不到会话会直接报错，不会悄悄新开。
- 会话上下文 = 最后一步的 `inputTokens + cacheReadTokens + cacheWriteTokens`。

## 验收
- 不要信 flash 的最终回复：自己重跑测试、重跑回测比哈希、抽样对照原始数据、派只读审查员。
- flash 的测试输出文件可能读不出汇总行，要自己重跑才能确认通过数。
- 提交给 Comet 时，`review.reviewer_execution_ref` 用描述性的标签，不要用内部的代理编号。
