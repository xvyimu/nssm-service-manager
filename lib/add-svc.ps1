# lib/add-svc.ps1 — CLI 添加服务（-Add Name,Port,Exe[,Url,Dir,Args,Env]）
#
# 2026-10-05 拆分：纯函数族（Test-SvcInput / ConvertTo-EnvPairs / Test-EnvPairs /
# Find-SensitiveEnvKeys / Get-NssmSetSpec）→ lib/svc-input.ps1；
# NSSM 注册/删除（Install-NssmService / Remove-NssmService）→ lib/nssm.ps1；
# GUI 对话框（Show-Add / Show-Remove）→ lib/dialogs.ps1。
# 本文件只剩 CLI 入口 Add-SvcFromCli 与自加载钩子。
#
# 自加载 config：CLI 模式（-Add）分支不加载 config.ps1，Wait-Stopped 需要默认值。
# Wait-Stopped 抽到 lib/svc-common.ps1，与 poll.ps1 的 runspace 引用同一份实现（原 SYNC 注释消除）。
if (-not $script:config) { . (Join-Path $PSScriptRoot 'config.ps1') }

# CLI 模式：解析逗号分隔参数，注册 NSSM 服务并启动，不弹 GUI
# 用法：-Add Name,Port,Exe[,Url,Dir,Args,Env]
#   Env 多对用分号分隔：KEY=VAL;KEY2=VAL2（逗号已被字段分隔符占用）
function Add-SvcFromCli([string]$spec){
  $parts = $spec -split ','
  if ($parts.Count -lt 3) { Write-Host "用法: -Add Name,Port,Exe[,Url,Dir,Args,Env]"; exit 1 }
  $n=$parts[0].Trim(); $p=[int]$parts[1].Trim(); $exe=$parts[2].Trim()
  $url=if($parts.Count -gt 3){$parts[3].Trim()}else{"http://127.0.0.1:$p"}
  $dir=if($parts.Count -gt 4){$parts[4].Trim()}else{''}
  $par=if($parts.Count -gt 5){$parts[5].Trim()}else{''}
  # Env：第 7 段往后全部属于 Env（Args 可能含逗号的情况不处理——Args 不应含逗号）
  # 多对 env 用分号分隔，避免与字段逗号冲突
  $envRaw=if($parts.Count -gt 6){($parts[6..($parts.Count-1)] -join ',').Trim()}else{''}
  # 校验顺序：名称 → 可执行文件 → 端口 → 重名（与 GUI 同，抽进 Test-SvcInput）
  $bad = Test-SvcInput $n $p $exe $script:svc
  if($bad){ Write-Host $bad.msg; exit 1 }
  $envPairs = ConvertTo-EnvPairs $envRaw ';'
  try {
    Install-NssmService $n $exe $dir $par $envPairs
  } catch { Write-Host "注册失败: $($_.Exception.Message)"; exit 1 }
  # 敏感键名提示：明文密钥会进注册表 AppEnvironmentExtra（BUILTIN\Users 可读）。
  # CLI 不阻断，只把命中键名列出来提示用户改用 *_FILE。
  $sensitive = Find-SensitiveEnvKeys $envPairs
  if ($sensitive.Count) {
    Write-Host "提示: 以下环境变量将明文写入注册表（BUILTIN\Users 可读）：$($sensitive -join ', ')"
    Write-Host "      推荐改用 *_FILE 路径让服务本体从密钥文件读，文件权限收口到 Administrators+SYSTEM。"
  }
  [Threading.Monitor]::Enter($sync.gate)
  try { $script:svc[$n]=@{port=$p;url=$url} } finally { [Threading.Monitor]::Exit($sync.gate) }
  try {
    Save-Svc $script:svc
  } catch {
    # Save-Svc 失败：NSSM 服务已注册且可用，但 services.json 未落盘。
    # 回滚 NSSM 会丢掉一个实际可用的服务，故不自动 remove——提示用户手动迁移。
    Write-Host "警告: 服务已注册但配置保存失败：$($_.Exception.Message)"
    Write-Host "$n 已在 NSSM 注册，请手动将其加入 services.json 或用 -Add 重新注册后删除旧服务。"
    exit 1
  }
  sc.exe start $n 2>&1 | Out-Null
  Write-Host "$n 已添加并启动 (port=$p url=$url)"
}

. (Join-Path $PSScriptRoot 'svc-common.ps1')
# 纯函数族与 NSSM 注册/删除已抽去各自文件——本文件自加载，保证 CLI 模式
# （service-manager-gui.ps1 -Add 分支只点源 util.ps1 + add-svc.ps1）拿得到全部依赖：
# svc-input.ps1（Test-SvcInput 等）→ nssm.ps1（Install-NssmService，其内部又用
# svc-input.ps1 的 Get-NssmSetSpec）→ svc-common.ps1（Wait-Stopped）。
. (Join-Path $PSScriptRoot 'svc-input.ps1')
. (Join-Path $PSScriptRoot 'nssm.ps1')
