#requires -Version 7.0
# T2/T3 回归：dialogs.ps1 的两个提交体此前零覆盖——弹模态框在测试里够不着，而 Click handler
# 内联体（校验顺序、Test-EnvPairs、敏感键 OKCancel 分支、Save 失败分支、删除入队与过渡态）
# 校验、注册、完成三段分别可测；按钮路径另外验证真实Dispatcher异步行为。
# MessageBox 是 WPF 静态调用，无头跑会阻塞——故替身掉 Show-DialogError / Confirm-SensitiveEnvKeys
# / Show-DialogWarning（生产里就是 MessageBox 的薄包装，见 dialogs.ps1）。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
foreach ($module in 'theme','util','svc-input','nssm','card','xaml','dialogs') { . (Join-Path $RepoRoot "lib/$module.ps1") }
. (Join-Path $PSScriptRoot 'test-helpers.ps1')

# 分阶段同步调用仅用于校验/幂等断言；真实按钮的异步路径另做Dispatcher测试。
function Submit-AddService($owner,[hashtable]$fields) {
  $request = Prepare-AddService $owner $fields
  if (-not $request) { return $false }
  try { $alreadyRegistered = Invoke-AddServiceRegistration $request @{} }
  catch { Show-DialogError $owner $_.Exception.Message; return $false }
  Complete-AddService $owner $request $alreadyRegistered
}

# ---- 夹具：队列/卡片缓存/svc，替身掉弹框与副作用 ----
$script:cmdQueue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:sync = @{ gate = [object]::new(); wake = [Threading.AutoResetEvent]::new($false) }
$script:cmdEpoch = 0
$script:svc = [ordered]@{}
$fakeExe = New-FakeExe 'sm-dlg'

# 弹框替身：记录调用，返回可编程结果（敏感键确认默认放行）
$script:dialogErrors = @(); $script:dialogWarnings = @(); $script:confirmAnswer = $true; $script:confirmSeen = $null
function Show-DialogError($owner, [string]$msg) { $script:dialogErrors += $msg }
function Show-DialogWarning($owner, [string]$msg, [string]$title) { $script:dialogWarnings += @{ msg=$msg; title=$title } }
# 单测不该受运行机器真实 ACL 影响：默认「不可写」，要验告警的用例自己置 '是' / '未知…'。
$script:exeDirVerdict = '否'
function Get-ExeDirVerdict([string]$exe) { return [string]$script:exeDirVerdict }
function Confirm-SensitiveEnvKeys($owner, [string]$tip) { $script:confirmSeen = $tip; $script:confirmAnswer }
# NSSM / 保存 替身
$script:installed = @()
function Test-ServicePresent { $false }
function Install-NssmService($n, $exe, $dir, $par, $envPairs, $account) { $script:installed += $n; $script:lastEnvPairs = @($envPairs); $script:lastAccount = $account }
$script:saved = $false
function Save-Svc($data) { $script:saved = $true }
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

  # ---- T3-b2：端口不是数字 ----
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

  # ---- T3-i2：LocalSystem + 可写 exe 目录 → 再多一条安全姿态提示，且仍继续注册 ----
  $script:exeDirVerdict = '是'
  $script:installed = @(); $script:dialogErrors = @(); $script:dialogWarnings = @()
  $ok = Submit-AddService $win @{ n='SvcG2'; p='8088'; exe=$fakeExe; url=''; dir=''; par=''; env=''
      account='LocalSystem'; gpu=$false }
  $script:exeDirVerdict = '否'
  Assert ($ok) '可写目录告警不该阻断注册。'
  Assert ($script:installed -contains 'SvcG2') '告警后应继续注册。'
  Assert ($script:dialogWarnings.Count -eq 1 -and $script:dialogWarnings[0].title -eq '安全姿态提示') "应弹一条安全姿态提示，got $($script:dialogWarnings.Count)"
  Assert ($script:dialogWarnings[0].msg -match 'SYSTEM') '提示应点明可被替换后以 SYSTEM 运行'

  # ---- T3-i3：LocalSystem + 读不到 ACL → 另一条非阻断提示，且不得说成安全 ----
  # 三态改成 '未知…' 后不能再压成「否（安全）」：这条守住「没检查 ≠ 安全」。
  $script:exeDirVerdict = '未知（无法读取 ACL：拒绝访问。）'
  $script:installed = @(); $script:dialogErrors = @(); $script:dialogWarnings = @()
  $ok = Submit-AddService $win @{ n='SvcG3'; p='8089'; exe=$fakeExe; url=''; dir=''; par=''; env=''
      account='LocalSystem'; gpu=$false }
  $script:exeDirVerdict = '否'
  Assert ($ok) 'ACL 读不到不该阻断注册。'
  Assert ($script:installed -contains 'SvcG3') '未知判定后应继续注册。'
  Assert ($script:dialogWarnings.Count -eq 1 -and $script:dialogWarnings[0].title -eq '安全姿态未知') "应弹一条「无法确认」提示，got $($script:dialogWarnings.Count)"
  Assert ($script:dialogWarnings[0].msg -match '不等于安全') '未知提示必须点明这不等于安全'

  # ---- T3-j：未知账户直接拒绝，不注册（静默回落会让用户以为按最小权限跑了）----
  $script:installed = @(); $script:dialogErrors = @(); $script:dialogWarnings = @()
  $ok = Submit-AddService $win @{ n='SvcH'; p='8087'; exe=$fakeExe; url=''; dir=''; par=''; env=''
      account='DOMAIN\someone'; gpu=$false }
  Assert (-not $ok) '未知运行账户应被拦下。'
  Assert ($script:installed.Count -eq 0) '账户校验失败仍注册了服务。'
  Assert ($script:dialogErrors[0] -match '不支持的运行账户') "账户错误文案不对：$($script:dialogErrors[0])"

  # ---- T3-k：探测方式 tcp——url 必须为空，probe 落进清单（数据库/gRPC 不再靠手改 services.json）----
  $script:installed = @(); $script:dialogErrors = @(); $script:dialogWarnings = @()
  $ok = Submit-AddService $win @{ n='SvcTcp'; p='8088'; exe=$fakeExe; url='http://127.0.0.1:8088'; dir=''; par=''; env=''; probe='tcp' }
  Assert ($ok) "选 tcp 应能注册：$($script:dialogErrors -join ' / ')"
  $tcpEntry = $script:svc['SvcTcp']
  Assert ($tcpEntry -and $tcpEntry.probe -eq 'tcp') "tcp 口径没有落进清单：$($tcpEntry | ConvertTo-Json -Compress)"
  Assert ($tcpEntry.url -eq '') 'tcp 口径必须置空 url（留着会让人以为探测按 HTTP 走）'

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
  Assert ($d.Probe.Items.Count -eq 4 -and (($d.Probe.Items | ForEach-Object { $_.Tag }) -join '|') -eq 'auto|tcp|http|none') '探测方式下拉应有 auto/tcp/http/none 四项'
  # 选 tcp：URL 置空并禁用；切回 auto 恢复可用（事件体不 GetNewClosure 会拿到 $null 控件）
  $d.Inputs.url.Text = 'http://127.0.0.1:1'
  $d.Probe.SelectedIndex = 1
  Assert ($d.Inputs.url.Text -eq '' -and -not $d.Inputs.url.IsEnabled) '选 tcp 应置空并禁用 URL'
  # 选 http（只看 HTTP 200）：URL 保留且可用
  $d.Inputs.url.Text = 'http://127.0.0.1:1'
  $d.Probe.SelectedIndex = 2
  Assert ($d.Inputs.url.Text -eq 'http://127.0.0.1:1' -and $d.Inputs.url.IsEnabled) '选 http 应保留 URL'
  # 选 none（无端口服务）：同样置空并禁用 URL
  $d.Inputs.url.Text = 'http://127.0.0.1:1'
  $d.Probe.SelectedIndex = 3
  Assert ($d.Inputs.url.Text -eq '' -and -not $d.Inputs.url.IsEnabled) '选 none 应置空并禁用 URL'
  $d.Probe.SelectedIndex = 0
  Assert ($d.Inputs.url.IsEnabled) '切回 auto 应恢复 URL 输入'

  # ---- T5：真实Click与模态消息循环，慢注册期间继续处理Dispatcher回调 ----
  $script:registrationState = [hashtable]::Synchronized(@{Calls=0;Request=$null;DelayMs=500;Fail=$false})
  function Start-AddServiceRegistration([hashtable]$request) {
    $ps=[powershell]::Create()
    [void]$ps.AddScript({
      param($state,$request)
      $state.Calls++
      $state.Request=$request
      Start-Sleep -Milliseconds $state.DelayMs
      if ($state.Fail) { throw 'injected background registration failure' }
      $false
    }).AddArgument($script:registrationState).AddArgument($request)
    @{PowerShell=$ps;Handle=$ps.BeginInvoke();Request=$request;Progress=@{Text="正在注册服务…"}}
  }
  $script:modalDlg = New-AddDialog
  $mw = $script:modalDlg.Window
  $mw.WindowStartupLocation='Manual'; $mw.Left=-4000; $mw.Top=-4000; $mw.ShowInTaskbar=$false
  $script:modalDlg.Inputs.name.Text='SvcModal'
  $script:modalDlg.Inputs.port.Text='8096'
  $script:modalDlg.Inputs.exe.Text=$fakeExe
  $script:modalDlg.Inputs.env.Text='NO_PROXY=127.0.0.1,localhost'
  $script:modalDlg.Account.SelectedIndex=1
  $script:clickElapsedMs=0; $script:busyTicks=0; $script:closeWasRejected=$false; $script:ownerCloseWasRejected=$false
  $heartbeat=[System.Windows.Threading.DispatcherTimer]::new()
  $heartbeat.Interval=[TimeSpan]::FromMilliseconds(20)
  $heartbeat.Add_Tick({
    if ($script:modalDlg.Registration.Operation) {
      $script:busyTicks++
      if ($script:busyTicks -eq 1) {
        $script:modalDlg.Ok.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        $script:modalDlg.Window.Close()
        $script:closeWasRejected=$script:modalDlg.Window.IsVisible
        $win.Close()
        $script:ownerCloseWasRejected=$win.IsVisible
      }
    }
  })
  $mw.Add_ContentRendered({
    $clickWatch=[Diagnostics.Stopwatch]::StartNew()
    $script:modalDlg.Ok.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    $script:clickElapsedMs=$clickWatch.ElapsedMilliseconds
  })
  $script:dialogFactory = ${function:New-AddDialog}
  function New-AddDialog { $script:modalDlg }
  function Confirm-ExitBusy { $true }
  $win.WindowStartupLocation='Manual'; $win.Left=-4000; $win.Top=-4000; $win.ShowInTaskbar=$false
  $win.Show()
  $heartbeat.Start()
  try { Show-Add $win; $modalResult=$mw.DialogResult }
  finally { $heartbeat.Stop(); Set-Item Function:New-AddDialog $script:dialogFactory; $win.Hide() }
  Assert ($modalResult -eq $true) 'Completed registration should close the modal dialog successfully.'
  Assert ($script:clickElapsedMs -lt 250) "Click handler waited for registration: $($script:clickElapsedMs)ms"
  Assert ($script:busyTicks -gt 0) 'Dispatcher heartbeat must run while registration is pending.'
  Assert $script:closeWasRejected 'Closing during registration must keep the result receiver alive.'
  Assert $script:ownerCloseWasRejected 'Owner/tray exit during registration must keep the result receiver alive.'
  Assert ($script:registrationState.Calls -eq 1) 'Repeated Click during registration must not register twice.'
  Assert ($script:registrationState.Request.account -eq 'NT AUTHORITY\LocalService') 'Selected account was not sent to the background worker.'
  Assert ($script:registrationState.Request.envPairs.Count -eq 1 -and $script:registrationState.Request.envPairs[0] -eq 'NO_PROXY=127.0.0.1,localhost') 'Environment value was split before the background worker.'
  Write-Output 'PASS: slow registration leaves Dispatcher responsive, rejects duplicate submission/closing, then persists and closes.'

  # 后台失败恢复可编辑表单，不保存也不下发启动。
  $script:registrationState.Calls=0; $script:registrationState.Fail=$true; $script:registrationState.DelayMs=30
  $script:modalDlg=New-AddDialog
  $mw=$script:modalDlg.Window
  $mw.WindowStartupLocation='Manual'; $mw.Left=-4000; $mw.Top=-4000; $mw.ShowInTaskbar=$false
  $script:modalDlg.Inputs.name.Text='SvcFailModal'
  $script:modalDlg.Inputs.port.Text='8097'
  $script:modalDlg.Inputs.exe.Text=$fakeExe
  $script:dialogErrors=@(); $script:saved=$false; $script:cmdQueue.Clear()
  $script:workerFailureObserved=$false
  $heartbeat=[System.Windows.Threading.DispatcherTimer]::new()
  $heartbeat.Interval=[TimeSpan]::FromMilliseconds(20)
  $heartbeat.Add_Tick({
    if ($script:dialogErrors.Count) {
      $script:workerFailureObserved=$script:modalDlg.Ok.IsEnabled -and -not $script:modalDlg.Registration.Operation
      $script:modalDlg.Window.Close()
    }
  })
  $mw.Add_ContentRendered({ $script:modalDlg.Ok.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)) })
  $heartbeat.Start()
  try { [void]$mw.ShowDialog() } finally { $heartbeat.Stop() }
  Assert $script:workerFailureObserved 'Registration failure must restore the editable form.'
  Assert ($script:dialogErrors.Count -eq 1 -and $script:dialogErrors[0] -match 'injected background registration failure') 'Background failure reason was lost.'
  Assert (-not $script:saved -and $script:cmdQueue.Count -eq 0) 'Failed background registration must not persist or start.'
  Write-Output 'PASS: background registration failure restores the form and reports the original error without save/start.'
  # ---- T3-f：Save-Svc 失败分支——服务已注册但没写清单；必须保持窗口并说清处置 ----
  # 原实现提示完就关窗，用户以为没加成，常见反应是再填一次 → NSSM 报服务已存在。
  $script:installed = @(); $script:dialogWarnings = @(); $script:dialogErrors = @()
  function Save-Svc($data) { throw '磁盘只读' }
  $ok = Submit-AddService $win @{ n='SvcD'; p='8083'; exe=$fakeExe; url=''; dir=''; par=''; env='' }
  Assert (-not $ok) 'Save 失败时必须保持窗口（返回 $false），否则用户看不到「加没加成」。'
  Assert ($script:installed -contains 'SvcD') 'Save 失败路径应已注册服务（不回滚 NSSM）。'
  Assert ($script:dialogErrors.Count -eq 1 -and $script:dialogErrors[0] -match '磁盘只读') 'Save 失败应把原因写进错误正文。'
  Assert ($script:dialogErrors[0] -match '已.*注册.*没写入清单') '错误正文应说清「已在 NSSM 注册但没写入清单」。'
  Assert (-not $script:svc.Contains('SvcD')) 'Save 失败后内存清单不得留着 SvcD（下一次保存会把它写进磁盘）。'

  # ---- probe=none：端口可留空，落盘 probe=none + port 0，URL 清空（rclone mount 这类服务） ----
  # 上面几段把 Save-Svc 换成了抛错替身，这段要验落盘形状，先还原成记录型替身。
  function Save-Svc($data) { $script:savedData = $data }
  $script:installed = @(); $script:dialogErrors = @()
  $ok = Submit-AddService $win @{ n='SvcP'; p=''; exe=$fakeExe; url='http://127.0.0.1:9000'; dir=''; par=''; env=''; probe='none' }
  Assert ($ok) "probe=none 且端口留空应通过：$($script:dialogErrors -join ' | ')"
  Assert ($script:svc.Contains('SvcP')) 'probe=none 应写入内存清单。'
  Assert ($script:svc['SvcP'].probe -eq 'none') "落盘 probe 不对：$($script:svc['SvcP'].probe)"
  Assert ($script:svc['SvcP'].port -eq 0) "落盘 port 应为 0：$($script:svc['SvcP'].port)"
  Assert ($script:svc['SvcP'].url -eq '') "none 口径 url 应清空：$($script:svc['SvcP'].url)"
  # 非 none 口径端口仍必填
  $script:dialogErrors = @()
  $ok = Submit-AddService $win @{ n='SvcQ'; p=''; exe=$fakeExe; url=''; dir=''; par=''; env='' }
  Assert (-not $ok) 'auto 口径下端口留空仍应被拦下。'

  Write-Output 'PASS: add-service stages cover required/port/env/account validation, probe=none (blank port accepted, probe/port/url persisted), sensitive-key OKCancel (cancel vs continue), account passthrough, GPU hint (non-blocking, suppressed for non-LocalSystem), success enqueue, probe=tcp shape, and Save-failure branch (window stays open); New-AddDialog builds a scrollable dialog with the 3 built-in accounts, LocalSystem preselected and an auto/tcp/http/none probe dropdown; real modal clicks keep Dispatcher responsive during background registration.'

  # ---- T2：Submit-RemoveCommand ----
  # 卡片在缓存：入队 remove 且置「删除中」过渡态
  $script:svc = [ordered]@{ RmSvc = @{ port=9000; url='http://127.0.0.1:9000' } }
  Render-Page

  # 慢注册不能占住Click处理器；真实模态/Dispatcher验收在下方。
  $slowDialog = New-AddDialog
  $slowDialog.Inputs.name.Text = 'SvcSlowClick'
  $slowDialog.Inputs.port.Text = '8097'
  $slowDialog.Inputs.exe.Text = $fakeExe
  function Install-NssmService { Start-Sleep -Milliseconds 500 }
  $clickWatch = [Diagnostics.Stopwatch]::StartNew()
  try { $slowDialog.Ok.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)) }
  catch { if ($_.Exception.Message -notmatch 'DialogResult') { throw } }
  Assert ($clickWatch.ElapsedMilliseconds -lt 250) "Click handler waited for registration: $($clickWatch.ElapsedMilliseconds)ms"
  $slowDialog.Window.Close()
  function Install-NssmService($n, $exe, $dir, $par, $envPairs, $account) { $script:installed += $n; $script:lastEnvPairs = @($envPairs); $script:lastAccount = $account }
  $script:cmdQueue.Clear()
  Submit-RemoveCommand 'RmSvc'
  $card = $script:cards['RmSvc']
  Assert ($card.ST -eq '删除中') "删除未置过渡态：$($card.ST)"
  Assert (-not $card.Btn.IsEnabled -and -not $card.ReadyToToggle) '删除中按钮未禁用。'
  Assert ($script:statusBar.Text -match '正在删除 RmSvc') "状态栏文案不对：$($script:statusBar.Text)"
  $cmd = $null; [void]$script:cmdQueue.TryDequeue([ref]$cmd)
  Assert ($cmd.n -eq 'RmSvc' -and $cmd.act -eq 'remove' -and $cmd.e -gt 0) "删除命令入队错误：$($cmd.n)/$($cmd.act)/$($cmd.e)"

  # 卡片不在缓存（else 分支）：仍入队删除，不置过渡态、不抛错
  $script:cmdQueue.Clear()
  Submit-RemoveCommand 'NotInCache'
  $cmd = $null; [void]$script:cmdQueue.TryDequeue([ref]$cmd)
  Assert ($cmd.n -eq 'NotInCache' -and $cmd.act -eq 'remove') '卡片不在缓存时未入队删除命令。'
  Assert ($script:statusBar.Text -match '正在删除 NotInCache') 'else 分支状态栏文案不对。'

  Write-Output 'PASS: Submit-RemoveCommand enqueues remove + sets transition when cached; enqueues without transition when uncached.'
} finally { $win.Close(); $script:sync.wake.Dispose(); Remove-Item -LiteralPath $fakeExe -Force -EA SilentlyContinue }
