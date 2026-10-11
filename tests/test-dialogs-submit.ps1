#requires -Version 7.0
# T2/T3 回归：dialogs.ps1 的两个提交体此前零覆盖——弹模态框在测试里够不着，而 Click handler
# 内联体（校验顺序、Test-EnvPairs、敏感键 OKCancel 分支、Save 失败分支、删除入队与过渡态）
# 全在 GUI 里，没有测试缝。现抽成 Submit-AddService / Submit-RemoveCommand，本测试直测真函数。
#
# MessageBox 是 WPF 静态调用，无头跑会阻塞——故替身掉 Show-DialogError / Confirm-SensitiveEnvKeys
# / Show-DialogWarning（生产里就是 MessageBox 的薄包装，见 dialogs.ps1）。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
foreach ($module in 'theme','util','svc-input','nssm','card','xaml','dialogs') { . (Join-Path $RepoRoot "lib/$module.ps1") }
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }

# ---- 夹具：队列/卡片缓存/svc，替身掉弹框与副作用 ----
$script:cmdQueue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:queue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:msgQueue = [Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:sync = @{ gate = [object]::new(); wake = [Threading.AutoResetEvent]::new($false) }
$script:cmdEpoch = 0
$script:svc = [ordered]@{}
$fakeExe = Join-Path ([IO.Path]::GetTempPath()) "sm-dlg-$([guid]::NewGuid().ToString('N')).exe"
[IO.File]::WriteAllText($fakeExe, 'placeholder', [Text.UTF8Encoding]::new($false))

# 弹框替身：记录调用，返回可编程结果（敏感键确认默认放行）
$script:dialogErrors = @(); $script:dialogWarnings = @(); $script:confirmAnswer = $true; $script:confirmSeen = $null
function Show-DialogError($owner, [string]$msg) { $script:dialogErrors += $msg }
function Show-DialogWarning($owner, [string]$msg, [string]$title) { $script:dialogWarnings += @{ msg=$msg; title=$title } }
function Confirm-SensitiveEnvKeys($owner, [string]$tip) { $script:confirmSeen = $tip; $script:confirmAnswer }
# NSSM / 保存 替身
$script:installed = @()
function Install-NssmService($n, $exe, $dir, $par, $envPairs) { $script:installed += $n }
$script:saved = $false
function Save-Svc($data) { $script:saved = $true }
function Stop-Background {}
$win = New-MainWindow
try {
  Render-Page

  # ---- T3-a：必填缺失被拦下，不注册 ----
  $script:installed = @(); $script:dialogErrors = @()
  $ok = Submit-AddService $win @{ n=''; p='8080'; exe=$fakeExe; url=''; dir=''; par=''; env='' }
  Assert (-not $ok) '缺少服务名应被拦下。'
  Assert ($script:installed.Count -eq 0) '校验失败仍调用了 Install-NssmService。'
  Assert ($script:dialogErrors.Count -eq 1) '应弹一次错误框。'

  # ---- T3-b：端口非法（文案 GUI 保留自己的措辞）----
  $script:dialogErrors = @()
  $ok = Submit-AddService $win @{ n='SvcA'; p='99999'; exe=$fakeExe; url=''; dir=''; par=''; env='' }
  Assert (-not $ok) '端口越界应被拦下。'
  Assert ($script:dialogErrors[0] -eq '端口必须是 1-65535') "端口文案错误：$($script:dialogErrors[0])"

  # ---- T3-c：env 格式错误被拦下（GUI 比 CLI 多一层校验）----
  $script:dialogErrors = @()
  $ok = Submit-AddService $win @{ n='SvcA'; p='8080'; exe=$fakeExe; url=''; dir=''; par=''; env='NOVALUE' }
  Assert (-not $ok) 'env 缺 = 应被拦下。'
  Assert ($script:dialogErrors[0] -match '格式错误') "env 错误文案不对：$($script:dialogErrors[0])"

  # ---- T3-d：敏感键 OKCancel 分支——取消则不注册 ----
  $script:installed = @(); $script:confirmAnswer = $false; $script:confirmSeen = $null
  $ok = Submit-AddService $win @{ n='SvcB'; p='8081'; exe=$fakeExe; url=''; dir=''; par=''; env='MY_API_KEY=sk-x' }
  Assert (-not $ok) '敏感键确认取消后不应注册。'
  Assert ($null -ne $script:confirmSeen -and $script:confirmSeen -match 'MY_API_KEY') '确认框应点名敏感键。'
  Assert ($script:installed.Count -eq 0) '取消确认后仍注册了服务。'

  # ---- T3-e：敏感键确认通过则继续注册，成功入队启动 ----
  $script:installed = @(); $script:confirmAnswer = $true; $script:cmdQueue.Clear(); $script:saved = $false
  $ok = Submit-AddService $win @{ n='SvcC'; p='8082'; exe=$fakeExe; url=''; dir=''; par=''; env='MY_API_KEY=sk-x' }
  Assert ($ok) '确认通过后应完成注册并关弹窗。'
  Assert ($script:installed -contains 'SvcC') '确认通过后未注册。'
  Assert ($script:saved) '注册成功后应落盘。'
  $cmd = $null; [void]$script:cmdQueue.TryDequeue([ref]$cmd)
  Assert ($cmd.n -eq 'SvcC' -and $cmd.act -eq 'start') "注册后应入队启动：$($cmd.n)/$($cmd.act)"
  Assert ($script:svc.Contains('SvcC') -and $script:svc['SvcC'].url -eq 'http://127.0.0.1:8082') '默认 URL 未按端口生成。'

  # ---- T3-f：Save-Svc 失败分支——服务已注册，提示手动迁移，仍关弹窗 ----
  $script:installed = @(); $script:dialogWarnings = @()
  function Save-Svc($data) { throw '磁盘只读' }
  $ok = Submit-AddService $win @{ n='SvcD'; p='8083'; exe=$fakeExe; url=''; dir=''; par=''; env='' }
  Assert ($ok) 'Save 失败时服务已注册，仍应关弹窗（与成功一致）。'
  Assert ($script:installed -contains 'SvcD') 'Save 失败路径未注册服务。'
  Assert ($script:dialogWarnings.Count -eq 1 -and $script:dialogWarnings[0].msg -match '磁盘只读') 'Save 失败应弹带原因的警告框。'
  Assert ($script:dialogWarnings[0].title -eq '保存失败') 'Save 失败警告标题不对。'

  Write-Output 'PASS: Submit-AddService covers required/port/env validation, sensitive-key OKCancel (cancel vs continue), success enqueue, and Save-failure branch.'

  # ---- T2：Submit-RemoveCommand ----
  # 卡片在缓存：入队 remove 且置「删除中」过渡态
  $script:svc = [ordered]@{ RmSvc = @{ port=9000; url='http://127.0.0.1:9000' } }
  Render-Page
  $script:cmdQueue.Clear()
  Submit-RemoveCommand 'RmSvc'
  $card = $script:cards['RmSvc']
  Assert ($card.ST -eq '删除中') "删除未置过渡态：$($card.ST)"
  Assert (-not $card.Btn.IsEnabled -and -not $card.ReadyToToggle) '删除中按钮未禁用。'
  Assert ($script:statusBar.Text -eq '正在删除 RmSvc ...') "状态栏文案不对：$($script:statusBar.Text)"
  $cmd = $null; [void]$script:cmdQueue.TryDequeue([ref]$cmd)
  Assert ($cmd.n -eq 'RmSvc' -and $cmd.act -eq 'remove' -and $cmd.e -gt 0) "删除命令入队错误：$($cmd.n)/$($cmd.act)/$($cmd.e)"

  # 卡片不在缓存（else 分支）：仍入队删除，不置过渡态、不抛错
  $script:cmdQueue.Clear()
  Submit-RemoveCommand 'NotInCache'
  $cmd = $null; [void]$script:cmdQueue.TryDequeue([ref]$cmd)
  Assert ($cmd.n -eq 'NotInCache' -and $cmd.act -eq 'remove') '卡片不在缓存时未入队删除命令。'
  Assert ($script:statusBar.Text -eq '正在删除 NotInCache ...') 'else 分支状态栏文案不对。'

  Write-Output 'PASS: Submit-RemoveCommand enqueues remove + sets transition when cached; enqueues without transition when uncached.'
} finally { $win.Close(); $script:sync.wake.Dispose(); Remove-Item -LiteralPath $fakeExe -Force -EA SilentlyContinue }
