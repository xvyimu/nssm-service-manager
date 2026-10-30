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
function Install-NssmService($n, $exe, $dir, $par, $envPairs, $account) { $script:installed += $n; $script:lastEnvPairs = @($envPairs); $script:lastAccount = $account }
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

  # ---- T3-b2：端口不是数字 —— 原来在 Test-SvcInput 之前就 [int] 强转，抛异常只写状态栏 ----
  $script:dialogErrors = @()
  $ok = Submit-AddService $win @{ n='SvcA'; p='3000ms'; exe=$fakeExe; url=''; dir=''; par=''; env='' }
  Assert (-not $ok) '非数字端口应被拦下（而不是抛异常）。'
  Assert ($script:dialogErrors[0] -eq '端口必须是 1-65535 的整数') "非数字端口文案错误：$($script:dialogErrors[0])"

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

  # ---- T3-g：env 值含逗号（多地址 NO_PROXY）应通过校验，并按**一条**下发 ----
  # 改前 ConvertTo-EnvPairs 无脑按逗号切，值是 127.0.0.1、localhost 两段，
  # localhost 没有 = 直接被 Test-EnvPairs 拦下——GUI 里压根没法填这种 NO_PROXY。
  $script:installed = @(); $script:dialogErrors = @(); $script:lastEnvPairs = $null
  $ok = Submit-AddService $win @{ n='SvcE'; p='8084'; exe=$fakeExe; url=''; dir=''; par=''; env='NO_PROXY=127.0.0.1,localhost' }
  Assert ($ok) "GUI 应接受含逗号的环境变量值，实际被拦：$($script:dialogErrors -join ' / ')"
  Assert ($script:lastEnvPairs.Count -eq 1 -and $script:lastEnvPairs[0] -eq 'NO_PROXY=127.0.0.1,localhost') "GUI 下发的 env 被拆坏：$($script:lastEnvPairs -join ' | ')"

  # ---- T3-h：运行账户透传；选了非 LocalSystem 时，GPU 勾选不该再提示 ----
  $script:installed = @(); $script:dialogErrors = @(); $script:dialogWarnings = @(); $script:lastAccount = $null
  $ok = Submit-AddService $win @{ n='SvcF'; p='8085'; exe=$fakeExe; url=''; dir=''; par=''; env=''
      account='NT AUTHORITY\LocalService'; gpu=$true }
  Assert ($ok) "内置账户应被接受：$($script:dialogErrors -join ' / ')"
  Assert ($script:lastAccount -eq 'NT AUTHORITY\LocalService') "运行账户没透传给 Install-NssmService：[$($script:lastAccount)]"
  Assert ($script:dialogWarnings.Count -eq 0) '已选非 LocalSystem 账户，不该再弹 LocalSystem 的提示'

  # ---- T3-i：GPU 勾选 + LocalSystem → 提示但**不阻断**注册 ----
  $script:installed = @(); $script:dialogErrors = @(); $script:dialogWarnings = @(); $script:lastAccount = $null
  $ok = Submit-AddService $win @{ n='SvcG'; p='8086'; exe=$fakeExe; url=''; dir=''; par=''; env=''
      account='LocalSystem'; gpu=$true }
  Assert ($ok) 'GPU 提示不该阻断注册。'
  Assert ($script:installed -contains 'SvcG') 'GPU 提示后应继续注册。'
  Assert ($script:dialogWarnings.Count -eq 1 -and $script:dialogWarnings[0].title -eq '运行账户提示') "应弹一条运行账户提示，got $($script:dialogWarnings.Count)"
  Assert ($script:dialogWarnings[0].msg -match 'LocalSystem') '提示应点明 LocalSystem'

  # ---- T3-j：未知账户直接拒绝，不注册（静默回落会让用户以为按最小权限跑了）----
  $script:installed = @(); $script:dialogErrors = @(); $script:dialogWarnings = @()
  $ok = Submit-AddService $win @{ n='SvcH'; p='8087'; exe=$fakeExe; url=''; dir=''; par=''; env=''
      account='DOMAIN\someone'; gpu=$false }
  Assert (-not $ok) '未知运行账户应被拦下。'
  Assert ($script:installed.Count -eq 0) '账户校验失败仍注册了服务。'
  Assert ($script:dialogErrors[0] -match '不支持的运行账户') "账户错误文案不对：$($script:dialogErrors[0])"

  # ---- T4：添加对话框的控件树（模态框在测试里打不开，但搭错了会在这里当场抛）----
  # 生产里这类错的表现是「点『添加服务』没反应」，读代码看不出来。
  $d = New-AddDialog
  Assert ($d.Window.Content -is [System.Windows.Controls.ScrollViewer]) '对话框内容应套 ScrollViewer——超长部分否则会被裁掉'
  # 高度跟内容走（折叠 3 个必填 vs 展开 9 项，差 300px），封顶交给 MaxHeight + 滚动
  Assert ($d.Window.SizeToContent -eq 'Height') "窗口高度应随内容自适应，got [$($d.Window.SizeToContent)]"
  Assert ([double]$d.Window.MaxHeight -eq 720) "应有高度上限，got [$($d.Window.MaxHeight)]"
  Assert ($d.Account.Items.Count -eq 3) "运行账户应有 3 个内置账户，got $($d.Account.Items.Count)"
  $tags = @($d.Account.Items | ForEach-Object { $_.Tag })
  Assert (($tags -join '|') -eq 'LocalSystem|NT AUTHORITY\LocalService|NT AUTHORITY\NetworkService') "账户选项不对：$($tags -join '|')"
  Assert ($d.Account.SelectedItem.Tag -eq 'LocalSystem') "默认账户应是 LocalSystem，got [$($d.Account.SelectedItem.Tag)]"
  Assert ($d.Gpu.IsChecked -eq $false) 'GPU 勾选默认应为未选'

  # ---- T5：点真的「注册并启动」按钮——走真处理器，不直调 Submit-AddService ----
  # 直调 Submit 测不出「处理器引用了已返回函数的局部变量」：PowerShell 脚本块不是闭包，
  # New-AddDialog 返回后它的局部作用域就没了。曾经因此点注册抛 null-valued 异常、
  # Submit 一次都没进，而所有测试仍是绿的。
  $script:installed = @(); $script:dialogErrors = @(); $script:dialogWarnings = @()
  $d.Inputs.name.Text = 'SvcClick'; $d.Inputs.port.Text = '8095'; $d.Inputs.exe.Text = $fakeExe
  $clickEx = $null
  try {
    $d.Ok.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
  } catch { $clickEx = $_.Exception.Message }
  Assert ($script:installed -contains 'SvcClick') "点「注册并启动」没走到 Install-NssmService（clickEx=$clickEx）"
  Assert ($script:dialogErrors.Count -eq 0) "点注册弹了错误框：$($script:dialogErrors -join ' / ')"
  # 夹具限制：这个窗口没有 ShowDialog 过，处理器末尾设 DialogResult 会抛。排除这一种即可。
  if ($clickEx) { Assert ($clickEx -match 'DialogResult') "点注册抛了非预期异常：$clickEx" }

  # ---- T6：真 ShowDialog 下点「注册并启动」（离屏窗口，不打扰桌面）----
  # T5 只证明处理器作用域对；这里走真模态消息循环，连 DialogResult / 关闭 / 下拉选中一起验。
  # 无交互桌面时跳过——那种环境下 ShowDialog 会永久阻塞。
  if ([Environment]::UserInteractive) {
    $script:installed = @(); $script:dialogErrors = @(); $script:lastAccount = $null; $script:lastEnvPairs = @()
    $script:modalDlg = New-AddDialog
    $mw = $script:modalDlg.Window
    $mw.WindowStartupLocation = 'Manual'; $mw.Left = -4000; $mw.Top = -4000; $mw.ShowInTaskbar = $false
    $script:modalDlg.Inputs.name.Text = 'SvcModal'
    $script:modalDlg.Inputs.port.Text = '8096'
    $script:modalDlg.Inputs.exe.Text  = $fakeExe
    $script:modalDlg.Inputs.env.Text  = 'NO_PROXY=127.0.0.1,localhost'
    $script:modalDlg.Account.SelectedIndex = 1        # LocalService
    $script:modalClickEx = $null
    $mw.Add_ContentRendered({
      try { $script:modalDlg.Ok.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)) }
      catch { $script:modalClickEx = $_.Exception.Message; $script:modalDlg.Window.Close() }
    })
    $mw.ShowDialog() | Out-Null
    Assert ($null -eq $script:modalClickEx) "真模态点击抛异常：$($script:modalClickEx)"
    Assert ($script:installed -contains 'SvcModal') '真模态点击没走到 Install-NssmService'
    Assert ($script:lastAccount -eq 'NT AUTHORITY\LocalService') "下拉选中的账户没传下去：[$($script:lastAccount)]"
    Assert ($script:lastEnvPairs.Count -eq 1 -and $script:lastEnvPairs[0] -eq 'NO_PROXY=127.0.0.1,localhost') "环境变量值被拆散：$($script:lastEnvPairs -join ' | ')"
    Write-Output 'PASS: real ShowDialog click registers with the selected account and an intact NO_PROXY value.'
  } else {
    Write-Output 'SKIP: 非交互会话，跳过 ShowDialog 模态测试（会永久阻塞）。'
  }

  # ---- T3-f：Save-Svc 失败分支——服务已注册，提示手动迁移，仍关弹窗 ----
  $script:installed = @(); $script:dialogWarnings = @()
  function Save-Svc($data) { throw '磁盘只读' }
  $ok = Submit-AddService $win @{ n='SvcD'; p='8083'; exe=$fakeExe; url=''; dir=''; par=''; env='' }
  Assert ($ok) 'Save 失败时服务已注册，仍应关弹窗（与成功一致）。'
  Assert ($script:installed -contains 'SvcD') 'Save 失败路径未注册服务。'
  Assert ($script:dialogWarnings.Count -eq 1 -and $script:dialogWarnings[0].msg -match '磁盘只读') 'Save 失败应弹带原因的警告框。'
  Assert ($script:dialogWarnings[0].title -eq '保存失败') 'Save 失败警告标题不对。'

  Write-Output 'PASS: Submit-AddService covers required/port/env/account validation, sensitive-key OKCancel (cancel vs continue), account passthrough, GPU hint (non-blocking, suppressed for non-LocalSystem), success enqueue, and Save-failure branch; New-AddDialog builds a scrollable dialog with the 3 built-in accounts and LocalSystem preselected; clicking the real "注册并启动" button reaches Install-NssmService (guards the non-closure trap).'

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
