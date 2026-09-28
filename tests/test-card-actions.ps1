#requires -Version 7.0
param([string]$RepoRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
foreach ($module in 'theme','util','card','xaml') { . (Join-Path $RepoRoot "lib/$module.ps1") }
$script:sync=@{wake=[Threading.AutoResetEvent]::new($false)}
$script:svc=[ordered]@{TestService=@{port=8080;url='http://127.0.0.1:8080'}}
function Stop-Background {}
function Invoke-CardInput($card,[string]$source,[int]$clicks=2) {
  if ($source -eq 'Button') {
    $card.Btn.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  } else {
    $eventArgs=[Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,0,[Windows.Input.MouseButton]::Left)
    $eventArgs.RoutedEvent=[Windows.UIElement]::MouseLeftButtonDownEvent
    $eventArgs.GetType().GetProperty('ClickCount').SetValue($eventArgs,$clicks)
    $card.RaiseEvent($eventArgs)
  }
}
function Assert($condition,[string]$message) { if (-not $condition) { throw $message } }
$win=New-MainWindow
try {
  $cases=@(
    @{State='已停止';Health='';Action='start'},
    @{State='运行中';Health='正常';Action='stop'},
    @{State='运行中';Health='无响应';Error='health'},
    @{State='运行中';Health='超时';Error='health'},
    @{State='启动中';Health='';Error='busy'},
    @{State='停止中';Health='';Error='busy'},
    @{State='查询中';Health='';Error='unknown'},
    @{State='未安装';Health='';Error='unknown'},
    @{State='未知';Health='';Error='unknown'},
    @{State='运行中';Health='正常';Error='cooldown'}
  )
  foreach ($source in 'Button','DoubleClick') {
    foreach ($case in $cases) {
      $card=New-Card 'TestService' $script:svc.TestService
      $script:cmdQueue=[Collections.Concurrent.ConcurrentQueue[object]]::new()
      Update-CardData $card.SvcName $case.State $case.Health
      if ($case.Error -eq 'cooldown') { $card.LastToggle=[datetime]::Now.AddSeconds(-4) }
      $lastToggle=$card.LastToggle
      [void]$script:sync.wake.Reset()
      Invoke-CardInput $card $source
      if ($case.Action) {
        Assert ($script:sync.wake.WaitOne(0)) 'Accepted command did not wake worker.'
        $command=$null
        Assert ($script:cmdQueue.TryDequeue([ref]$command)) "$source did not queue $($case.Action)."
        Assert ($command.n -eq 'TestService' -and $command.act -eq $case.Action) 'Wrong queue payload.'
        $expectedState=if ($case.Action -eq 'start') {'启动中'} else {'停止中'}
        Assert ($card.ST -eq $expectedState -and $card.Btn.Content -eq $expectedState) 'Transition display changed.'
        Assert (-not $card.Btn.IsEnabled -and -not $card.ReadyToToggle) 'Transition must disable toggle.'
        Assert ($card.LastToggle -gt $lastToggle -and $card.Dot.Fill.Color -eq [Windows.Media.Colors]::Orange) 'Transition feedback changed.'
      } else {
        Assert (-not $script:sync.wake.WaitOne(0)) 'Rejected command woke worker.'
        Assert ($script:cmdQueue.IsEmpty -and $card.ST -eq $case.State -and $card.LastToggle -eq $lastToggle) "$source guard changed state or queued an action."
        $expected=switch ($case.Error) {
          'health' { if ($source -eq 'Button') {'TestService 服务未就绪，暂不能关闭'} else {'TestService 服务未就绪（健康非正常），暂不能关闭'} }
          'busy' { if ($source -eq 'Button') {'TestService 正在切换中'} else {'TestService 正在切换中，请稍候'} }
          'unknown' {'TestService 状态尚未就绪'}
          'cooldown' { $null }
        }
        if ($expected) { Assert ($script:statusBar.Text -eq $expected) "$source feedback changed: $($case.Error)" }
        else {
          $pattern=if ($source -eq 'Button') {'^TestService 请等待 [1-8]s$'} else {'^TestService 请等待 [1-8]s 再操作$'}
          Assert ($script:statusBar.Text -match $pattern) 'Cooldown feedback changed.'
        }
      }
    }
  }
  $script:cmdQueue.Clear()
  $card=New-Card 'TestService' $script:svc.TestService
  Update-CardData $card.SvcName '已停止' ''
  Invoke-CardInput $card 'DoubleClick' 1
  Assert ($script:cmdQueue.IsEmpty) 'Single card click must not start a service.'
  Write-Output 'PASS: both input paths preserve 20 state/guard cases and feedback; single-click ignored.'
} finally { $win.Close(); $script:sync.wake.Dispose() }
