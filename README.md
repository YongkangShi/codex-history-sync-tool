# Codex History Sync Tool

一个用于修复 Codex Desktop 本地历史对话归属的小工具。

当你切换 API、中转服务、官方账号、`model_provider` 或模型后，Codex Desktop 有时会出现“本地历史还在，但左侧会话列表看不到”的情况。本工具会检查本机 Codex 的本地数据库、会话文件和侧边栏索引，并把旧历史重新同步到当前配置。

## 功能特点

- 查看本机历史线程当前属于哪些 Provider 和 Model
- 默认只同步 `model_provider`，用于找回左侧历史列表
- 可选同步 `model_provider + model`，用于把旧记录归一到当前模型
- 自动重建 `session_index.jsonl` 侧边栏索引
- 同步前自动备份数据库、侧边栏索引和会话文件首行元数据
- 支持从备份恢复
- 提供 Windows 图形界面，也支持命令行
- 兼容官方账号配置：`config.toml` 没有 `model_provider` 时默认按 `openai` 处理
- 遇到磁盘空间不足或会话文件被 Codex 占用时，会跳过该会话文件及对应数据库记录，并继续处理其他记录

## 适用场景

- 从官方账号切到中转 Provider 后，旧历史消失
- 从中转 Provider 切回官方账号后，旧历史消失
- 修改了 `model_provider` 或 `model`
- 侧边栏索引丢失或不完整
- 本地历史文件仍在 `%USERPROFILE%\.codex`，但 Codex Desktop 左侧列表看不到

## 不适用场景

- 云端账号之间同步聊天记录
- 本地历史文件已经被删除
- 跨电脑迁移完整历史
- 批量改写线程的项目目录 `cwd`

## 运行环境

- Windows
- PowerShell 5.1 或更高版本
- Python 3.10 或更高版本，并可通过 `py -3` 调用
- 本机存在 Codex Desktop 数据目录，默认是 `%USERPROFILE%\.codex`

## 快速开始

克隆或下载本项目后，在项目目录打开 PowerShell。

### 启动图形界面

```powershell
powershell -NoProfile -Sta -File .\launch_ui.ps1
```

界面中主要有两个同步按钮：

- `只同步 Provider`：只更新 `model_provider`，这是找回历史列表的默认选择。
- `同步 Provider + Model`：同时更新 `model_provider` 和 `model`，适合你明确想把旧会话模型也改成当前模型时使用。

### 创建桌面入口

```powershell
.\launch_ui.ps1 -InstallShortcutOnly
```

如果安全软件拦截快捷方式，通常是误报。当前快捷方式已避免使用 `ExecutionPolicy Bypass` 和隐藏窗口启动参数，仍被拦截时可以将项目目录加入安全软件信任区。

## 命令行用法

### 查看状态

```powershell
py -3 .\sync_backend.py --json status
```

默认状态只把 Provider 差异计入“待同步”。如果要把 Model 差异也计入：

```powershell
py -3 .\sync_backend.py --json status --include-model
```

### 只同步 Provider

```powershell
py -3 .\sync_backend.py --json sync
```

这是默认同步模式，不会修改历史记录里的 `model`。

### 同步 Provider + Model

```powershell
py -3 .\sync_backend.py --json sync --include-model
```

只有加上 `--include-model` 时，工具才会同步 `model`。

### 手动备份

```powershell
py -3 .\sync_backend.py --json backup
```

### 从最新备份恢复

```powershell
py -3 .\sync_backend.py --json restore
```

### 从指定备份恢复

```powershell
py -3 .\sync_backend.py --json restore --backup "C:\Users\你\.codex\history_sync_backups\state_5.sqlite.pre-sync.20260606-180241.bak"
```

## 数据与备份

工具会读取和修改以下本机文件：

- `%USERPROFILE%\.codex\config.toml`
- `%USERPROFILE%\.codex\state_5.sqlite`
- `%USERPROFILE%\.codex\session_index.jsonl`
- `%USERPROFILE%\.codex\sessions\**\rollout-*.jsonl`

每次同步前都会自动备份：

- `state_5.sqlite`
- `session_index.jsonl`
- 每个会话文件第一行的 `session_meta`

备份默认保存在：

```text
%USERPROFILE%\.codex\history_sync_backups
```

如果有会话文件被跳过，跳过明细会写入：

```text
%USERPROFILE%\.codex\history_sync_backups\skipped_sessions
```

## 安全策略

### 首行会话元数据

Codex 的会话文件是 JSONL，第一行通常保存 `session_meta`。工具只改写这一行里的 `model_provider` 和可选的 `model`，不会改写后续对话内容。

### 首行变短或等长

如果新首行不比旧首行长，工具会在原文件内就地覆盖，并用空格补齐长度，避免创建大临时文件。

### 首行变长

如果新首行更长，工具会创建临时文件并流式复制原文件内容，再原子替换原文件。

### 空间不足或文件被占用

如果磁盘空间不足，或 Codex 正在占用某个会话文件，工具会跳过该会话文件，并同步跳过对应数据库记录，避免数据库和会话文件不一致。

## 官方账号与中转配置

中转配置通常包含：

```toml
model_provider = "gpt"

[model_providers.gpt]
base_url = "https://example.com/v1"
```

官方账号配置可能没有 `model_provider` 和 `[model_providers]`。这种情况下，Codex 默认使用 `openai`，本工具也会按 `openai` 处理。

## 建议流程

1. 打开图形界面。
2. 点击 `重新检查`。
3. 优先使用 `只同步 Provider` 找回历史。
4. 如果确实需要统一模型，再使用 `同步 Provider + Model`。
5. 同步后重启 Codex Desktop，等待侧边栏刷新。

## 常见问题

### 为什么有些文件被跳过？

常见原因有两个：

- `insufficient_disk_space_for_temp_rewrite`：首行变长，需要临时文件，但当前磁盘空间不足。
- `file_busy_during_rewrite`：该会话文件正在被 Codex 占用。

跳过文件不会导致数据库和会话文件不一致，因为对应数据库记录也会一起跳过。

### 为什么同步后仍然看不到某些历史？

新版 Codex 可能还会按当前项目目录过滤历史。如果同步后仍看不到旧对话，请确认是否打开了旧对话原来的项目目录。本工具默认不批量改写 `cwd`。

### 恢复备份会恢复什么？

恢复会还原数据库、侧边栏索引和已备份的会话文件首行元数据。恢复前工具会再创建一份当前状态的安全备份，方便反悔。

## 开发与测试

运行测试：

```powershell
py -3 -m unittest discover -s tests -v
```

主要文件：

- `sync_backend.py`：状态检查、同步、备份、恢复逻辑
- `launch_ui.ps1`：Windows 图形界面
- `tests/test_sync_backend.py`：后端单元测试

## 上游项目与致谢

本项目基于 [GODGOD126/codex-history-sync-tool](https://github.com/GODGOD126/codex-history-sync-tool) 改进而来。

当前版本在原有思路基础上，补充了 Provider-only 默认同步、可选 Model 同步、会话文件首行安全改写、磁盘空间不足跳过、文件占用跳过、跳过明细报告、备份恢复增强和 Windows 图形界面优化等能力。

## 免责声明

本工具会直接操作本机 Codex Desktop 的本地状态文件。工具已尽量通过自动备份、跳过策略和测试降低风险，但使用前仍建议确认你理解同步和恢复的影响。
