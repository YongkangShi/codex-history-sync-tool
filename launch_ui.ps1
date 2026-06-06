param(
  [switch]$InstallShortcutOnly,
  [switch]$SmokeTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:UiScriptPath = $MyInvocation.MyCommand.Path
$script:ToolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:BackendPath = Join-Path $script:ToolRoot 'sync_backend.py'
$script:ShortcutName = 'Codex 对话同步工具.lnk'
$script:IconLocation = 'C:\Windows\System32\imageres.dll,15'
$script:BackupMap = @{}
$script:LatestState = $null

function Invoke-Backend {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  if (-not (Test-Path -LiteralPath $script:BackendPath)) {
    throw "缺少后端脚本: $script:BackendPath"
  }

  $output = & py -3 $script:BackendPath @Arguments 2>&1
  $exitCode = $LASTEXITCODE
  $text = (($output | ForEach-Object { "$_" }) -join [Environment]::NewLine).Trim()
  if (-not $text) {
    throw '后端没有返回任何内容。'
  }

  try {
    $json = $text | ConvertFrom-Json
  } catch {
    throw "后端 JSON 解析失败。`r`n原始错误: $($_.Exception.Message)`r`n返回内容:`r`n$text"
  }

  if ($exitCode -ne 0 -or -not $json.ok) {
    if ($json.error) {
      throw [string]$json.error
    }
    throw "后端执行失败。`r`n$text"
  }

  return $json
}

function New-DesktopShortcut {
  $desktopPath = [Environment]::GetFolderPath('Desktop')
  $shortcutPath = Join-Path $desktopPath $script:ShortcutName
  $targetPath = Join-Path $PSHOME 'powershell.exe'
  $arguments = "-NoProfile -Sta -File `"$script:UiScriptPath`""

  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($shortcutPath)
  $shortcut.TargetPath = $targetPath
  $shortcut.Arguments = $arguments
  $shortcut.WorkingDirectory = $script:ToolRoot
  $shortcut.IconLocation = $script:IconLocation
  $shortcut.Description = 'Codex history sync UI safe launcher'
  $shortcut.Save()

  return $shortcutPath
}

if ($InstallShortcutOnly) {
  $createdShortcut = New-DesktopShortcut
  Write-Output "桌面快捷方式已创建: $createdShortcut"
  exit 0
}

function Append-Log {
  param([string]$Message)

  $timestamp = Get-Date -Format 'HH:mm:ss'
  $logBox.AppendText("[$timestamp] $Message`r`n")
  $logBox.SelectionStart = $logBox.TextLength
  $logBox.ScrollToCaret()
}

function Format-Counts {
  param($Counts)

  if (-not $Counts -or $Counts.Count -eq 0) {
    return '无'
  }

  return (($Counts | ForEach-Object { "$($_.provider)=$($_.count)" }) -join ', ')
}

function Format-ModelCounts {
  param($Counts)

  if (-not $Counts -or $Counts.Count -eq 0) {
    return '无'
  }

  return (($Counts | ForEach-Object { "$($_.model)=$($_.count)" }) -join ', ')
}

function Format-Duration {
  param($Milliseconds)

  if ($null -eq $Milliseconds) {
    return '0 秒'
  }

  $seconds = [Math]::Round(([double]$Milliseconds / 1000), 1)
  return "$seconds 秒"
}

function Format-ByteSize {
  param($Bytes)

  if ($null -eq $Bytes) {
    return '0 B'
  }

  $value = [double]$Bytes
  if ($value -ge 1GB) {
    return "$([Math]::Round($value / 1GB, 2)) GB"
  }
  if ($value -ge 1MB) {
    return "$([Math]::Round($value / 1MB, 1)) MB"
  }
  return "$([Math]::Round($value, 0)) B"
}

function Get-RewriteSpaceNote {
  param($Status)

  if (-not $Status.rewrite_space_check) {
    return ''
  }

  $space = $Status.rewrite_space_check
  if ([int]$space.would_skip_file_count -gt 0) {
    return "`r`n`r`n空间预估：当前可用空间约 $(Format-ByteSize $space.free_bytes)，最大临时改写需要约 $(Format-ByteSize $space.required_free_bytes)。预计会跳过 $($space.would_skip_file_count) 个大型会话文件；对应数据库记录也会保持不动。释放空间后可以再次同步剩余部分。"
  }
  if ([int]$space.rewrite_file_count -gt 0) {
    return "`r`n`r`n空间预估：$($space.rewrite_file_count) 个会话文件需要临时改写，当前空间足够。"
  }
  return ''
}

function Get-SessionProviderMismatchCount {
  param($Status)

  $total = 0
  foreach ($row in $Status.session_provider_counts) {
    if ([string]$row.provider -ne [string]$Status.current_provider) {
      $total += [int]$row.count
    }
  }
  return $total
}

function Get-SessionModelMismatchCount {
  param($Status)

  if (-not $Status.current_model) {
    return 0
  }

  $total = 0
  foreach ($row in $Status.session_model_counts) {
    if ([string]$row.model -ne [string]$Status.current_model) {
      $total += [int]$row.count
    }
  }
  return $total
}

function Set-Busy {
  param(
    [bool]$Busy,
    [string]$Message = ''
  )

  foreach ($button in @($refreshButton, $syncProviderButton, $syncProviderModelButton, $backupButton, $restoreButton, $restoreLatestButton, $shortcutButton)) {
    if ($button) {
      $button.Enabled = -not $Busy
    }
  }
  if ($openBackupsButton) {
    $openBackupsButton.Enabled = $true
  }

  if ($Busy) {
    $statusLabel.Text = $Message
    $progressBar.Style = 'Marquee'
    $progressBar.Visible = $true
  } else {
    $progressBar.Style = 'Blocks'
    $progressBar.Visible = $false
    if ($script:LatestState) {
      $statusLabel.Text = Get-FriendlyStatus $script:LatestState
    } else {
      $statusLabel.Text = '准备就绪'
    }
  }
}

function Get-FriendlyStatus {
  param($Status)

  $providerPending = [int]$Status.provider_movable_threads + (Get-SessionProviderMismatchCount $Status) + [int]$Status.missing_session_index_entries
  $modelPending = [int]$Status.model_movable_threads + (Get-SessionModelMismatchCount $Status)

  if ($providerPending -le 0 -and $modelPending -le 0) {
    return '一切正常：历史记录和模型都已经同步到当前设置。'
  }

  if ($providerPending -le 0) {
    return '历史找回已完成：Provider 和侧边栏索引正常；模型归一为可选项。'
  }

  $parts = @()
  if ([int]$Status.provider_movable_threads -gt 0) {
    $parts += "$($Status.provider_movable_threads) 条数据库 Provider 待同步"
  }
  $sessionProviderPending = Get-SessionProviderMismatchCount $Status
  if ($sessionProviderPending -gt 0) {
    $parts += "$sessionProviderPending 个会话文件 Provider 待同步"
  }
  if ([int]$Status.missing_session_index_entries -gt 0) {
    $parts += "$($Status.missing_session_index_entries) 条侧边栏索引待补回"
  }
  return "历史找回需要处理：" + ($parts -join '，') + '。'
}

function Refresh-State {
  $status = Invoke-Backend @('--json', 'status')
  Apply-State $status
  Append-Log "状态已刷新：$(Get-FriendlyStatus $status)"
}

function Start-Sync {
  param(
    [bool]$IncludeModel
  )

  if ($IncludeModel) {
    $script:LatestState = Invoke-Backend @('--json', 'status', '--include-model')
    Apply-State $script:LatestState
    Append-Log "状态已刷新（包含模型）：$(Get-FriendlyStatus $script:LatestState)"
  } elseif (-not $script:LatestState -or $script:LatestState.include_model) {
    Refresh-State
  }

  $pendingCount = [int]$script:LatestState.movable_threads

  if ($pendingCount -le 0) {
    $message = if ($IncludeModel) {
      '当前 Provider 和模型都已经整理好了，不需要再同步。'
    } else {
      '当前 Provider 已经整理好了，不需要再同步。'
    }
    [System.Windows.Forms.MessageBox]::Show($message, '无需同步', 'OK', 'Information') | Out-Null
    Append-Log "同步跳过：$message"
    return
  }

  $modeLabel = if ($IncludeModel) { 'Provider + Model' } else { '仅 Provider' }
  $spaceNote = Get-RewriteSpaceNote $script:LatestState
  $message = if ($IncludeModel) {
    $sessionModelPending = Get-SessionModelMismatchCount $script:LatestState
    "将把历史记录同步到当前 Provider 和 Model：`r`nProvider: $($script:LatestState.current_provider)`r`nModel: $($script:LatestState.current_model)`r`n`r`n将处理：`r`n- 数据库中 $($script:LatestState.model_movable_threads) 条 Model 不同的线程`r`n- 会话文件中 $sessionModelPending 个缺少或不同 Model 的记录`r`n- 侧边栏索引会重新生成`r`n`r`n工具会先自动备份。同步 Model 可能会让部分旧会话文件首行变长；如果磁盘空间不足或文件正被 Codex 占用，会跳过对应会话文件及其数据库记录，并继续处理其他文件。$spaceNote"
  } else {
    $sessionProviderPending = Get-SessionProviderMismatchCount $script:LatestState
    "将只把历史记录同步到当前 Provider：`r`nProvider: $($script:LatestState.current_provider)`r`n`r`n将处理：`r`n- 数据库中 $($script:LatestState.provider_movable_threads) 条 Provider 不同的线程`r`n- 会话文件中 $sessionProviderPending 个 Provider 不同的记录`r`n- 侧边栏索引会重新生成`r`n`r`n工具会先自动备份。此模式不会修改历史 Model；如果会话文件首行变长时磁盘空间不足，或文件正被 Codex 占用，会跳过对应会话文件及其数据库记录，并继续处理其他文件。$spaceNote"
  }

  if (-not (Confirm-Action -Message $message -Title "开始同步 $modeLabel？")) {
    Append-Log "用户取消了 $modeLabel 同步。"
    return
  }

  Set-Busy -Busy $true -Message "正在同步历史（$modeLabel），Codex 忙的时候会自动等一会儿..."
  try {
    $backendArgs = @('--json', 'sync')
    if ($IncludeModel) {
      $backendArgs += '--include-model'
    }
    $result = Invoke-Backend $backendArgs
    Append-Log "$modeLabel 同步完成。数据库更新 $($result.updated_rows) 条，会话文件更新 $($result.updated_session_files) 个。"
    Append-Log "等待数据库空闲: $(Format-Duration $result.lock_wait_ms)，总耗时: $(Format-Duration $result.timing.total_ms)。"
    Append-Log "数据库同步前: $(Format-Counts $result.before_counts)"
    Append-Log "数据库同步后: $(Format-Counts $result.after_counts)"
    Append-Log "模型同步前: $(Format-ModelCounts $result.before_model_counts)"
    Append-Log "模型同步后: $(Format-ModelCounts $result.after_model_counts)"
    Append-Log "会话文件同步前: $(Format-Counts $result.session_before_counts)"
    Append-Log "会话文件同步后: $(Format-Counts $result.session_after_counts)"
    Append-Log "侧边栏索引已重建: $($result.rewritten_index_entries) 条，补回 $($result.missing_session_index_entries_before) 条。"
    Append-Log "备份文件: $($result.backup_path)"
    if ($result.skipped_session_file_count -and [int]$result.skipped_session_file_count -gt 0) {
      Append-Log "本次跳过 $($result.skipped_session_file_count) 个会话文件（磁盘空间不足或文件被占用）。"
      Append-Log "对应数据库记录已跳过: $($result.excluded_database_thread_count) 条。"
      foreach ($skipped in $result.skipped_session_files) {
        Append-Log "跳过: $($skipped.thread_id)    原因: $($skipped.reason)    路径: $($skipped.path)"
      }
      if ($result.skipped_session_report_path) {
        Append-Log "跳过明细文件: $($result.skipped_session_report_path)"
      }
    } else {
      Append-Log "本次没有跳过会话文件。"
    }
    Apply-State $result.status
    Append-Log "========== 本次同步日志结束：$modeLabel =========="
    [System.Windows.Forms.MessageBox]::Show('同步完成。如果侧边栏没有马上刷新，重新打开 Codex 即可。', '同步完成', 'OK', 'Information') | Out-Null
  } finally {
    Set-Busy -Busy $false
  }
}

function Apply-State {
  param($Status)

  $script:LatestState = $Status

  $sessionProviderPending = Get-SessionProviderMismatchCount $Status
  $providerPending = [int]$Status.provider_movable_threads + $sessionProviderPending + [int]$Status.missing_session_index_entries
  $providerState = if ($providerPending -le 0) { '已完成' } else { '需处理' }
  $indexState = if ([int]$Status.missing_session_index_entries -le 0) { "完整，$($Status.indexed_threads) 条" } else { "缺 $($Status.missing_session_index_entries) 条" }

  $sessionModelPending = Get-SessionModelMismatchCount $Status
  $modelPending = [int]$Status.model_movable_threads + $sessionModelPending
  $modelState = if ($modelPending -le 0) { '已完成' } else { '可选同步' }
  $sessionModelText = "会话文件模型: $sessionModelPending 个缺少或不同"
  if ($Status.rewrite_space_check -and [int]$Status.rewrite_space_check.would_skip_file_count -gt 0) {
    $sessionModelText += "，预计跳过 $($Status.rewrite_space_check.would_skip_file_count) 个大文件"
  }

  $currentModelText = if ($Status.current_model) { [string]$Status.current_model } else { '未读取到' }
  $sessionProviderText = "会话文件 Provider: $sessionProviderPending 个待同步"
  if (-not $Status.include_model -and $Status.rewrite_space_check -and [int]$Status.rewrite_space_check.would_skip_file_count -gt 0) {
    $sessionProviderText += "，预计跳过 $($Status.rewrite_space_check.would_skip_file_count) 个大文件"
  }
  $providerLabel.Text = "当前配置    Provider: $($Status.current_provider)    模型: $currentModelText    数据位置: $($Status.codex_home)"
  $modelLabel.Text = "历史找回（只同步 Provider）：$providerState"
  $summaryLabel.Text = "数据库 Provider: $($Status.provider_movable_threads) 条待同步    $sessionProviderText    侧边栏索引: $indexState"
  $repairLabel.Text = "模型归一（Provider + Model）：$modelState"
  $pathLabel.Text = "数据库模型: $($Status.model_movable_threads) 条不同    $sessionModelText"
  $statusLabel.Text = Get-FriendlyStatus $Status

  $providersView.Items.Clear()
  foreach ($row in $Status.provider_counts) {
    $isCurrent = if ($row.provider -eq $Status.current_provider) { '当前' } else { '' }
    $item = New-Object System.Windows.Forms.ListViewItem([string]$row.provider)
    [void]$item.SubItems.Add([string]$row.count)
    [void]$item.SubItems.Add('数据库')
    [void]$item.SubItems.Add($isCurrent)
    [void]$providersView.Items.Add($item)
  }
  foreach ($row in $Status.session_provider_counts) {
    $isCurrent = if ($row.provider -eq $Status.current_provider) { '当前' } else { '' }
    $item = New-Object System.Windows.Forms.ListViewItem([string]$row.provider)
    [void]$item.SubItems.Add([string]$row.count)
    [void]$item.SubItems.Add('会话文件')
    [void]$item.SubItems.Add($isCurrent)
    [void]$providersView.Items.Add($item)
  }
  $backupList.Items.Clear()
  $script:BackupMap = @{}
  foreach ($backup in $Status.backups) {
    $label = "$($backup.modified_at)    $($backup.name)"
    $script:BackupMap[$label] = $backup.path
    [void]$backupList.Items.Add($label)
  }
  $backupList.HorizontalExtent = 900
}

function Confirm-Action {
  param(
    [string]$Message,
    [string]$Title = '确认操作'
  )

  $choice = [System.Windows.Forms.MessageBox]::Show(
    $Message,
    $Title,
    [System.Windows.Forms.MessageBoxButtons]::OKCancel,
    [System.Windows.Forms.MessageBoxIcon]::Question
  )

  return $choice -eq [System.Windows.Forms.DialogResult]::OK
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Codex 历史找回助手'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1040, 800)
$form.MinimumSize = New-Object System.Drawing.Size(1040, 800)
$form.BackColor = [System.Drawing.Color]::FromArgb(246, 248, 251)
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

$headerLabel = New-Object System.Windows.Forms.Label
$headerLabel.Text = 'Codex 历史找回助手'
$headerLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 18, [System.Drawing.FontStyle]::Bold)
$headerLabel.AutoSize = $true
$headerLabel.Location = New-Object System.Drawing.Point(24, 18)
$form.Controls.Add($headerLabel)

$introLabel = New-Object System.Windows.Forms.Label
$introLabel.Text = '用于把“换了 API / Provider / 登录方式后看不见的本地历史”重新挂回当前 Codex。Codex 开着也可以试，工具会等待数据库空闲。'
$introLabel.ForeColor = [System.Drawing.Color]::FromArgb(77, 89, 105)
$introLabel.AutoSize = $true
$introLabel.MaximumSize = New-Object System.Drawing.Size(850, 0)
$introLabel.Location = New-Object System.Drawing.Point(26, 54)
$form.Controls.Add($introLabel)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = '正在读取状态...'
$statusLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(28, 84, 160)
$statusLabel.AutoSize = $true
$statusLabel.MaximumSize = New-Object System.Drawing.Size(970, 0)
$statusLabel.Location = New-Object System.Drawing.Point(26, 92)
$form.Controls.Add($statusLabel)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(28, 124)
$progressBar.Size = New-Object System.Drawing.Size(840, 8)
$progressBar.Visible = $false
$form.Controls.Add($progressBar)

$providerLabel = New-Object System.Windows.Forms.Label
$providerLabel.Text = '当前账号/Provider:'
$providerLabel.AutoSize = $true
$providerLabel.Location = New-Object System.Drawing.Point(28, 150)
$form.Controls.Add($providerLabel)

$modelLabel = New-Object System.Windows.Forms.Label
$modelLabel.Text = '当前模型:'
$modelLabel.AutoSize = $true
$modelLabel.Location = New-Object System.Drawing.Point(28, 174)
$form.Controls.Add($modelLabel)

$summaryLabel = New-Object System.Windows.Forms.Label
$summaryLabel.Text = '历史线程:'
$summaryLabel.AutoSize = $true
$summaryLabel.Location = New-Object System.Drawing.Point(28, 198)
$form.Controls.Add($summaryLabel)

$repairLabel = New-Object System.Windows.Forms.Label
$repairLabel.Text = '待修复:'
$repairLabel.AutoSize = $true
$repairLabel.Location = New-Object System.Drawing.Point(28, 222)
$form.Controls.Add($repairLabel)

$pathLabel = New-Object System.Windows.Forms.Label
$pathLabel.Text = '数据位置:'
$pathLabel.AutoSize = $true
$pathLabel.Location = New-Object System.Drawing.Point(28, 246)
$pathLabel.MaximumSize = New-Object System.Drawing.Size(970, 0)
$form.Controls.Add($pathLabel)

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = '重新检查'
$refreshButton.Size = New-Object System.Drawing.Size(110, 36)
$refreshButton.Location = New-Object System.Drawing.Point(28, 286)
$form.Controls.Add($refreshButton)

$syncProviderButton = New-Object System.Windows.Forms.Button
$syncProviderButton.Text = '只同步 Provider'
$syncProviderButton.Size = New-Object System.Drawing.Size(140, 36)
$syncProviderButton.Location = New-Object System.Drawing.Point(150, 286)
$syncProviderButton.BackColor = [System.Drawing.Color]::FromArgb(32, 91, 177)
$syncProviderButton.ForeColor = [System.Drawing.Color]::White
$syncProviderButton.FlatStyle = 'Flat'
$form.Controls.Add($syncProviderButton)

$syncProviderModelButton = New-Object System.Windows.Forms.Button
$syncProviderModelButton.Text = '同步 Provider + Model'
$syncProviderModelButton.Size = New-Object System.Drawing.Size(170, 36)
$syncProviderModelButton.Location = New-Object System.Drawing.Point(304, 286)
$syncProviderModelButton.BackColor = [System.Drawing.Color]::FromArgb(91, 103, 127)
$syncProviderModelButton.ForeColor = [System.Drawing.Color]::White
$syncProviderModelButton.FlatStyle = 'Flat'
$form.Controls.Add($syncProviderModelButton)

$backupButton = New-Object System.Windows.Forms.Button
$backupButton.Text = '先做备份'
$backupButton.Size = New-Object System.Drawing.Size(110, 36)
$backupButton.Location = New-Object System.Drawing.Point(488, 286)
$form.Controls.Add($backupButton)

$openBackupsButton = New-Object System.Windows.Forms.Button
$openBackupsButton.Text = '打开备份'
$openBackupsButton.Size = New-Object System.Drawing.Size(110, 36)
$openBackupsButton.Location = New-Object System.Drawing.Point(610, 286)
$form.Controls.Add($openBackupsButton)

$shortcutButton = New-Object System.Windows.Forms.Button
$shortcutButton.Text = '更新桌面入口'
$shortcutButton.Size = New-Object System.Drawing.Size(130, 36)
$shortcutButton.Location = New-Object System.Drawing.Point(732, 286)
$form.Controls.Add($shortcutButton)

$providersBox = New-Object System.Windows.Forms.GroupBox
$providersBox.Text = '历史归属'
$providersBox.Location = New-Object System.Drawing.Point(28, 342)
$providersBox.Size = New-Object System.Drawing.Size(430, 178)
$form.Controls.Add($providersBox)

$providersView = New-Object System.Windows.Forms.ListView
$providersView.View = 'Details'
$providersView.FullRowSelect = $true
$providersView.GridLines = $true
$providersView.Location = New-Object System.Drawing.Point(12, 26)
$providersView.Size = New-Object System.Drawing.Size(406, 140)
[void]$providersView.Columns.Add('账号/Provider', 170)
[void]$providersView.Columns.Add('数量', 70)
[void]$providersView.Columns.Add('位置', 100)
[void]$providersView.Columns.Add('状态', 60)
$providersBox.Controls.Add($providersView)

$backupsBox = New-Object System.Windows.Forms.GroupBox
$backupsBox.Text = '安全备份'
$backupsBox.Location = New-Object System.Drawing.Point(478, 342)
$backupsBox.Size = New-Object System.Drawing.Size(520, 178)
$form.Controls.Add($backupsBox)

$backupList = New-Object System.Windows.Forms.ListBox
$backupList.Location = New-Object System.Drawing.Point(12, 24)
$backupList.Size = New-Object System.Drawing.Size(496, 102)
$backupList.HorizontalScrollbar = $true
$backupList.IntegralHeight = $false
$backupsBox.Controls.Add($backupList)

$restoreButton = New-Object System.Windows.Forms.Button
$restoreButton.Text = '恢复选中备份'
$restoreButton.Size = New-Object System.Drawing.Size(122, 32)
$restoreButton.Location = New-Object System.Drawing.Point(12, 136)
$backupsBox.Controls.Add($restoreButton)

$restoreLatestButton = New-Object System.Windows.Forms.Button
$restoreLatestButton.Text = '恢复最新备份'
$restoreLatestButton.Size = New-Object System.Drawing.Size(122, 32)
$restoreLatestButton.Location = New-Object System.Drawing.Point(146, 136)
$backupsBox.Controls.Add($restoreLatestButton)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ScrollBars = 'Both'
$logBox.WordWrap = $false
$logBox.ReadOnly = $true
$logBox.Location = New-Object System.Drawing.Point(28, 540)
$logBox.Size = New-Object System.Drawing.Size(970, 190)
$logBox.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($logBox)

$refreshButton.Add_Click({
  try {
    Refresh-State
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '刷新失败', 'OK', 'Error') | Out-Null
    Append-Log "刷新失败: $($_.Exception.Message)"
  }
})

$syncProviderButton.Add_Click({
  try {
    Start-Sync -IncludeModel $false
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '同步失败', 'OK', 'Error') | Out-Null
    Append-Log "同步失败: $($_.Exception.Message)"
  }
})

$syncProviderModelButton.Add_Click({
  try {
    Start-Sync -IncludeModel $true
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '同步失败', 'OK', 'Error') | Out-Null
    Append-Log "同步失败: $($_.Exception.Message)"
  }
})

$backupButton.Add_Click({
  try {
    Set-Busy -Busy $true -Message '正在创建安全备份...'
    $result = Invoke-Backend @('--json', 'backup')
    Append-Log "手动备份完成: $($result.backup_path)"
    Append-Log "备份耗时: $(Format-Duration $result.timing.total_ms)"
    Refresh-State
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '备份失败', 'OK', 'Error') | Out-Null
    Append-Log "备份失败: $($_.Exception.Message)"
  } finally {
    Set-Busy -Busy $false
  }
})

$openBackupsButton.Add_Click({
  try {
    if (-not $script:LatestState) {
      Refresh-State
    }
    $folder = $script:LatestState.backup_dir
    if (-not (Test-Path -LiteralPath $folder)) {
      New-Item -ItemType Directory -Force -Path $folder | Out-Null
    }
    Start-Process explorer.exe $folder
    Append-Log "已打开备份目录: $folder"
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '打开目录失败', 'OK', 'Error') | Out-Null
    Append-Log "打开备份目录失败: $($_.Exception.Message)"
  }
})

$shortcutButton.Add_Click({
  try {
    $path = New-DesktopShortcut
    Append-Log "桌面入口已更新: $path"
    [System.Windows.Forms.MessageBox]::Show("桌面入口已更新：`r`n$path", '完成', 'OK', 'Information') | Out-Null
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '创建入口失败', 'OK', 'Error') | Out-Null
    Append-Log "创建入口失败: $($_.Exception.Message)"
  }
})

$restoreButton.Add_Click({
  try {
    if ($backupList.SelectedItem -eq $null) {
      [System.Windows.Forms.MessageBox]::Show('请先在右侧选一个备份。', '未选择备份', 'OK', 'Warning') | Out-Null
      return
    }
    $selectedLabel = [string]$backupList.SelectedItem
    $backupPath = $script:BackupMap[$selectedLabel]
    if (-not $backupPath) {
      throw '无法解析选中的备份路径。'
    }

    $message = "将恢复这个备份：`r`n$backupPath`r`n`r`n恢复前会再自动做一份当前状态备份，方便反悔。"
    if (-not (Confirm-Action -Message $message -Title '确认恢复？')) {
      Append-Log '用户取消了恢复。'
      return
    }

    Set-Busy -Busy $true -Message '正在恢复备份...'
    $result = Invoke-Backend @('--json', 'restore', '--backup', $backupPath)
    Append-Log "恢复完成。来源备份: $($result.restored_from)"
    Append-Log "恢复前安全备份: $($result.safety_backup)"
    Append-Log "恢复耗时: $(Format-Duration $result.timing.total_ms)"
    Apply-State $result.status
    Append-Log "========== 本次恢复日志结束：选中备份 =========="
    [System.Windows.Forms.MessageBox]::Show('恢复完成。建议重新打开 Codex 再看历史列表。', '恢复完成', 'OK', 'Information') | Out-Null
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '恢复失败', 'OK', 'Error') | Out-Null
    Append-Log "恢复失败: $($_.Exception.Message)"
    Append-Log "========== 本次恢复日志结束：选中备份 =========="
  } finally {
    Set-Busy -Busy $false
  }
})

$restoreLatestButton.Add_Click({
  try {
    if (-not (Confirm-Action -Message '将恢复最新备份，并在恢复前再做一次当前状态备份。' -Title '确认恢复最新备份？')) {
      Append-Log '用户取消了恢复最新备份。'
      return
    }

    Set-Busy -Busy $true -Message '正在恢复最新备份...'
    $result = Invoke-Backend @('--json', 'restore')
    Append-Log "已恢复最新备份: $($result.restored_from)"
    Append-Log "恢复前安全备份: $($result.safety_backup)"
    Append-Log "恢复耗时: $(Format-Duration $result.timing.total_ms)"
    Apply-State $result.status
    Append-Log "========== 本次恢复日志结束：最新备份 =========="
    [System.Windows.Forms.MessageBox]::Show('恢复完成。建议重新打开 Codex 再看历史列表。', '恢复完成', 'OK', 'Information') | Out-Null
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '恢复失败', 'OK', 'Error') | Out-Null
    Append-Log "恢复失败: $($_.Exception.Message)"
    Append-Log "========== 本次恢复日志结束：最新备份 =========="
  } finally {
    Set-Busy -Busy $false
  }
})

try {
  Refresh-State
} catch {
  Append-Log "初始化状态失败: $($_.Exception.Message)"
  [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '启动失败', 'OK', 'Error') | Out-Null
}

if ($SmokeTest) {
  Write-Output 'Smoke test OK'
  exit 0
}

[void]$form.ShowDialog()
