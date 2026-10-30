#requires -Version 7.0
# F5 重载清单：外部改动可发现、可同步，且不打断在途命令。
# 修前：只有重启 GUI 一条路；载入后手改 services.json 会被 Save-Svc 的 mtime 门闩拒写，
# 用户看到的提示是「关闭重开 GUI」。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
foreach ($module in 'theme','util','card','xaml') { . (Join-Path $RepoRoot "lib/$module.ps1") }
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }

$dir = Join-Path ([IO.Path]::GetTempPath()) "sm-reload-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force $dir | Out-Null
$cfg = Join-Path $dir 'services.json'
$utf8 = [Text.UTF8Encoding]::new($false)
function Write-Cfg([string]$text) { Start-Sleep -Milliseconds 30; [IO.File]::WriteAllText($cfg, $text, $utf8) }
function Stop-Background {}
try {
  Write-Cfg '{"A":{"port":1111,"url":""}}'
  $script:svc = Load-Svc
  $script:sync = @{ gate = [object]::new(); svc = $script:svc; stop = $true }
  $script:cmdQueue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
  $script:cmdEpoch = 0
  $win = New-MainWindow
  $script:cards = @{}
  $script:curPage = 0
  Render-Page

  Assert ($script:cards.Count -eq 1 -and $script:cards.ContainsKey('A')) '初始应渲染 1 张卡'
  Assert ($script:cards['A'].PortText.Text -eq ':1111') "端口文案错误：$($script:cards['A'].PortText.Text)"
  Assert (-not (Test-SvcFileChanged)) '没有外部改动时不该报变化'

  # ---- 1. 外部新增 → 检测 + 重载（缓存复用，不重建已有卡）----
  $cardA = $script:cards['A']
  Write-Cfg '{"A":{"port":1111,"url":""},"B":{"port":2222,"url":""}}'
  Assert (Test-SvcFileChanged) '外部修改应被检测到'
  Assert (-not (Test-SvcFileChanged)) '同一处改动只提示一次'
  $err = Invoke-SvcReload
  Assert ($null -eq $err) "重载应成功，got [$err]"
  Assert ($script:svc.Count -eq 2 -and $script:svc.Contains('B')) '重载后清单应含新服务'
  Assert ($script:cards.ContainsKey('B')) '重载后应渲染新卡片'
  Assert ([object]::ReferenceEquals($cardA, $script:cards['A'])) '未变的服务应复用原卡片对象'
  Assert ([object]::ReferenceEquals($script:sync.svc, $script:svc)) '后台的 $sync.svc 必须指向新清单'
  Assert ($script:cardPanel.Children.Count -eq 2) '面板应有两张卡'
  Assert (-not (Test-SvcFileChanged)) '重载后不该再报变化'

  # ---- 2. 外部改端口 → 已缓存卡的端点跟着刷新 ----
  Write-Cfg '{"A":{"port":1111,"url":""},"B":{"port":3333,"url":""}}'
  $null = Invoke-SvcReload
  Assert ($script:cards['B'].PortText.Text -eq ':3333') "端口未刷新：$($script:cards['B'].PortText.Text)"

  # ---- 3. 外部删除 → 卡片被摘掉 ----
  Write-Cfg '{"B":{"port":3333,"url":""}}'
  $null = Invoke-SvcReload
  Assert (-not $script:cards.ContainsKey('A')) '被删的服务卡片应移除'
  Assert ($script:cardPanel.Children.Count -eq 1) '面板应只剩一张卡'

  # ---- 4. 有在途命令：拒绝重载（否则回执落在不存在的卡上）----
  $script:cards['B'].ST = '启动中'
  Write-Cfg '{"C":{"port":4444,"url":""}}'
  $err = Invoke-SvcReload
  Assert ($err -and $err -match '正在切换') "过渡态应拒绝重载，got [$err]"
  Assert ($script:svc.Contains('B') -and $script:cards.ContainsKey('B')) '拒绝重载时清单与卡片都不能动'

  # ---- 5. 解析失败：原清单保持不变，且不误报成功 ----
  $script:cards['B'].ST = '运行中'
  Write-Cfg '[]'
  $err = Invoke-SvcReload
  Assert ($err -and $err -match '解析失败') "坏清单应拒绝重载，got [$err]"
  Assert ($script:svc.Contains('B')) '拒绝重载时清单必须保持原样'
  Assert ($script:svcLoadFailed) '坏清单应置 svcLoadFailed，让后续 Save-Svc 也拒写'
} finally {
  try { $win.Close() } catch {}
  Remove-Item -LiteralPath $dir -Recurse -Force -EA SilentlyContinue
} #guard-ok

Write-Output 'PASS: F5 重载能检测外部改动、复用缓存卡、增删差异；过渡态与坏清单都拒绝重载。'
