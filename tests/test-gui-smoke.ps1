#requires -Version 7.0
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
. (Join-Path $RepoRoot 'tests/test-helpers.ps1')
function Assert($condition, [string]$message) {
  if (-not $condition) { throw $message }
}
function Send-CardMouse($card, [Windows.Input.MouseButton]$button, [int]$clicks) {
  $eventArgs = [Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice, 0, $button)
  $eventArgs.RoutedEvent = if ($button -eq 'Left') { [Windows.UIElement]::MouseLeftButtonDownEvent } else { [Windows.UIElement]::MouseRightButtonDownEvent }
  $eventArgs.GetType().GetProperty('ClickCount').SetValue($eventArgs, $clicks)
  $card.RaiseEvent($eventArgs)
}

$cfg = Join-Path $RepoRoot 'services.json'
foreach ($module in 'theme','util','card','xaml') { . (Join-Path $RepoRoot "lib/$module.ps1") }
$script:svc = Load-Svc
$script:cmdQueue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:sync = @{wake=[Threading.AutoResetEvent]::new($false)}
# No worker, NSSM, or service calls: exercise actual WPF handlers against the queue.
$script:backgroundStopped = $false
function Stop-Background { $script:backgroundStopped = $true }
$win = New-MainWindow
try {
  Render-Page
  Assert ($win -is [Windows.Window]) 'Main window returned extra pipeline objects.'
  Assert ($script:cardPanel.Children.Count -eq [Math]::Min(6, $script:svc.Count)) 'Wrong card count.'
  $win.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$script:iconPath)
  $win.ShowActivated = $false
  $win.ShowInTaskbar = $false
  $win.WindowStartupLocation = 'Manual'
  $win.Left = -10000
  $win.Show()
  $win.UpdateLayout()
  $titleBar=$win.Content.Child.Children[0]
  Assert ($titleBar.InputHitTest([Windows.Point]::new(280,3)) -eq $titleBar) 'Empty title-bar area does not receive drag input.'
  Write-Output "PASS: WPF window, icon, $($script:cardPanel.Children.Count) cards."

  foreach ($size in @(@(1040,640),@(840,540),@(1280,800))) {
    $win.Width=$size[0]; $win.Height=$size[1]; $win.UpdateLayout()
    $first=$script:cardPanel.Children[0].TranslatePoint([Windows.Point]::new(0,0),$script:cardPanel)
    $third=$script:cardPanel.Children[2].TranslatePoint([Windows.Point]::new(0,0),$script:cardPanel)
    $fourth=$script:cardPanel.Children[3].TranslatePoint([Windows.Point]::new(0,0),$script:cardPanel)
    Assert ([Math]::Abs($first.Y-$third.Y) -lt 1 -and $third.X -gt $first.X) 'First row is not three columns.'
    Assert ([Math]::Abs($first.X-$fourth.X) -lt 1 -and $fourth.Y -gt $first.Y) 'Second row does not align.'
    Assert ($script:cardPanel.Children[0].ActualWidth -gt 220 -and $script:cardPanel.Children[0].ActualHeight -gt 180) 'Cards became too small.'
    Assert ($script:cardPanel.ActualHeight -gt $win.ActualHeight*0.7) 'Cards do not occupy the main content area.'
  }
  Assert ($script:btnNext.Visibility -eq 'Collapsed') 'Single-page navigation must be hidden.'
  Write-Output 'PASS: 3x2 layout at 840x540, 1040x640, 1280x800; single-page navigation hidden.'

  $card = $script:cardPanel.Children[0]
  foreach ($case in @(@('运行中','正常','Green'), @('运行中','超时','Orange'), @('运行中','无响应','Red'), @('运行中','HTTP 500','Red'), @('已停止','','Gray'))) {
    Update-CardData $card.SvcName $case[0] $case[1]
    Assert ($card.Dot.Fill.Color -eq [Windows.Media.Colors]::($case[2])) "Wrong state color: $($case[0]) / $($case[1])"
  }
  Send-CardMouse $card Left 2
  Assert ($script:cmdQueue.Count -eq 1) 'Double click did not queue start.'
  $queued = $null
  [void]$script:cmdQueue.TryPeek([ref]$queued)
  Assert ($queued.act -eq 'start') 'Wrong start action.'
  Update-CardData $card.SvcName '运行中' '正常'
  Send-CardMouse $card Left 2
  Assert ($script:cmdQueue.Count -eq 1) 'Eight-second cooldown did not block repeated toggle.'
  $card.LastToggle = [datetime]::MinValue
  Update-CardData $card.SvcName '运行中' '无响应'
  Send-CardMouse $card Left 2
  Assert ($script:cmdQueue.Count -eq 1) 'Unhealthy service bypassed stop gate.'
  Update-CardData $card.SvcName '运行中' '正常'
  Send-CardMouse $card Left 2
  Assert ($script:cmdQueue.Count -eq 2) 'Healthy stop did not reach queue.'
  Write-Output 'PASS: four colors, double-click start/stop, cooldown, health gate.'

  $lastToggle=$card.LastToggle
  $script:svc['__sm_layout_test__']=@{port=65535;url='http://127.0.0.1:65535'}
  $script:curPage=1; Render-Page
  Assert ($script:cardPanel.Children.Count -eq 1 -and $script:btnPrev.Visibility -eq 'Visible') 'Second page not accessible.'
  $script:curPage=0; Render-Page
  Assert ([Object]::ReferenceEquals($card,$script:cardPanel.Children[0])) 'Pagination replaced service card.'
  Assert ($card.LastToggle -eq $lastToggle) 'Pagination reset cooldown.'
  Update-CardData $card.SvcName '运行中' '正常'
  Send-CardMouse $card Left 2
  Assert ($script:cmdQueue.Count -eq 2) 'Pagination bypassed cooldown.'
  $script:svc.Remove('__sm_layout_test__'); Render-Page
  Write-Output 'PASS: pagination retains card identity and cooldown.'

  Send-CardMouse $card Right 1
  $menus = @([Windows.PresentationSource]::CurrentSources | ForEach-Object {
    if ($_.RootVisual) { Get-VisualNodes $_.RootVisual }
  } | Where-Object { $_ -is [Windows.Controls.ContextMenu] })
  Assert ($menus.Count -eq 1) 'Context menu was not created.'
  $menu = $menus[0]
  Assert ($menu.Items.Count -eq 7) 'Context menu must contain seven actions.'
  foreach ($i in 0..2) {
    $menu.Items[$i].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
  }
  Assert ($script:cmdQueue.Count -eq 5) 'Start/stop/restart menu actions did not queue.'
  function Start-Process([string]$FilePath) { $script:opened=$FilePath }
  function Show-Log([string]$name,$owner) { $script:logged=$name }
  function Show-SecurityCheck([string]$name) { $script:checked=$name }
  function Show-Remove([string]$name,$owner) { $script:removed=$name }
  foreach ($i in 3..6) {
    $menu.Items[$i].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
  }
  Assert ($script:opened -eq $script:svc[$card.SvcName].url) 'Panel action did not reach the URL opener.'
  Assert ($script:logged -eq $card.SvcName -and $script:checked -eq $card.SvcName) 'Log/security action targeted wrong service.'
  Assert ($script:removed -eq $card.SvcName) 'Remove action targeted wrong service.'
  $menu.IsOpen = $false
  Write-Output 'PASS: all seven menu actions reach their targets (side effects mocked).'

  $buttons = @(Get-VisualNodes $win | Where-Object { $_ -is [Windows.Controls.Button] })
  $minimize = $buttons | Where-Object { $_.Content -eq '—' }
  $maximize = $buttons | Where-Object { $_.Content -eq '▢' }
  $close = $buttons | Where-Object { $_.Content -eq '✕' }
  Assert ($null -ne $minimize -and $null -ne $maximize -and $null -ne $close) 'Title bar buttons not found.'
  $minimize.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  Assert ($win.WindowState -eq 'Minimized') 'Minimize handler failed.'
  $win.WindowState = 'Normal'
  $maximize.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  Assert ($win.WindowState -eq 'Maximized') 'Maximize handler failed.'
  $maximize.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  Assert ($win.WindowState -eq 'Normal') 'Maximize toggle did not restore.'
  $close.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  Assert $script:backgroundStopped 'Close did not run background cleanup.'
  Write-Output 'PASS: minimize, maximize toggle, and close handlers.'
} finally {
  if ($win.IsLoaded) { $win.Close() }
  $script:sync.wake.Dispose()
}
