#requires -Version 7.0
# 回归：退出确认框不得把无头测试卡死，也不得为已经不存在的服务弹窗。
# 背景：卡片在途时关窗会走 Add_Closing 的确认框。原来直接调 MessageBox —— 非交互进程里
# 它是真弹窗、永久阻塞，run-all 会停在一个「有操作在途：TestService」的框上等人工点「是」。
# 修法：确认改走 dialogs.ps1 的 Confirm-ExitBusy（NSSM_SM_HEADLESS=1 直接放行，run-all 设这个），
# 在途清单改走 Get-ExitBusy（只算 services.json 里还存在的服务，残留卡片不弹）。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
foreach ($module in 'config','util','dialogs') { . (Join-Path $RepoRoot "lib/$module.ps1") }
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }

# ---- 在途清单：残留卡片不算 ----
$cards = [ordered]@{
  TestService = @{ SvcName = 'TestService'; ST = '启动中' }   # 清单里已没有 → 等不到回执，不弹
  ComfyUI     = @{ SvcName = 'ComfyUI';     ST = '停止中' }   # 清单里在   → 弹
  ARTEX       = @{ SvcName = 'ARTEX';       ST = '运行中' }   # 非过渡态   → 不算
}
$svc = [ordered]@{ ComfyUI = @{ port = 8188 }; ARTEX = @{ port = 18787 } }
$busy = @(Get-ExitBusy $cards $svc)
Assert ($busy.Count -eq 1) "在途清单应只剩清单内的过渡态卡片，实际 $($busy.Count) 个：$(($busy | ForEach-Object { $_.SvcName }) -join ',')"
Assert ($busy[0].SvcName -eq 'ComfyUI') "在途清单应只含 ComfyUI，实际 $($busy[0].SvcName)"
Write-Output 'PASS: 残留卡片（服务已删除/重载）不进退出确认清单。'

# 清单为空/未加载时保守放行：宁可问，也别把在途操作当成没有
$busyNull = @(Get-ExitBusy $cards $null)
Assert ($busyNull.Count -eq 2) "清单未加载时应按全部过渡态卡片计数（2），实际 $($busyNull.Count)"
Write-Output 'PASS: 清单未加载时按全部过渡态卡片计数。'

# ---- 无头模式：不许真弹窗（这一步在 CI 里就是把原来那个永久阻塞变绿） ----
$env:NSSM_SM_HEADLESS = '1'
$ok = Confirm-ExitBusy $null '1 个服务还在切换中：TestService'
Assert ($ok -eq $true) "无头模式下 Confirm-ExitBusy 应直接返回 Yes，实际 $ok"
Remove-Item Env:NSSM_SM_HEADLESS -ErrorAction SilentlyContinue
Write-Output 'PASS: NSSM_SM_HEADLESS=1 时退出确认不弹窗并放行。'

# 没有可见窗口时同样不许弹（无头测试的窗口从不 Show；被代码直接 Close 也会走这条）
$ok2 = Confirm-ExitBusy $null '1 个服务还在切换中：TestService'
Assert ($ok2 -eq $true) "无可见窗口时 Confirm-ExitBusy 应直接返回 Yes，实际 $ok2"
Write-Output 'PASS: 没有可见窗口时退出确认不弹窗并放行。'

# ---- 结构守卫：关窗路径不许再直接调 MessageBox（绕开替身就会重新卡死 CI） ----
$xaml = Get-Content (Join-Path $RepoRoot 'lib/xaml.ps1') -Raw -Encoding utf8
Assert (-not ($xaml -match 'System\.Windows\.MessageBox')) 'lib/xaml.ps1 里仍有直接 MessageBox 调用，应改走 dialogs.ps1 的 Confirm-ExitBusy'
Write-Output 'PASS: 关窗确认走 Confirm-ExitBusy，xaml.ps1 不再直接调 MessageBox。'
