#requires -Version 7.0
# 发现 1 的红测试：删除服务后 $script:cards 缓存不清理，同名重建复用旧卡显示旧端口/URL。
# 修前：红（卡片 Port/Url/Tag 仍是旧值）。
# 修后：绿（Show-Remove 清 cards + Render-Page 命中缓存时刷新 Port/Url/Tag）。
param([string]$RepoRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
foreach ($module in 'theme','util','card','xaml') { . (Join-Path $RepoRoot "lib/$module.ps1") }
$script:sync=@{wake=[Threading.AutoResetEvent]::new($false)}
$script:svc=[ordered]@{}
function Stop-Background {}
function Assert($condition,[string]$message) { if (-not $condition) { throw $message } }

# Save-Svc / NSSM / sc.exe 替身：删除路径不落盘、不调外部命令
function Save-Svc($data) {}
$script:nssm='Invoke-TestNssm'
function Invoke-TestNssm { $global:LASTEXITCODE=0 }
function sc.exe { $global:LASTEXITCODE=0 }

$win=New-MainWindow
try {
  # ---- 1. 添加服务 X（端口 8080 / 旧 URL）----
  $script:svc['X']=@{port=8080;url='http://127.0.0.1:8080/old'}
  Render-Page
  $card=$script:cards['X']
  Assert ($card -ne $null) 'Card not created on add.'
  Assert ($card.Port -eq 8080 -and $card.Url -eq 'http://127.0.0.1:8080/old') 'Initial port/url not cached.'

  # ---- 2. 删除服务 X ----
  # 复现 Show-Remove 成功后的状态：svc 移除、Save-Svc 落盘。
  # 当前实现的 bug：Show-Remove 漏了 $script:cards.Remove($n)。
  # 直接执行 svc.Remove（cards 缓存残留），再 Render-Page 让卡片从面板消失。
  $script:svc.Remove('X')
  Render-Page
  Assert ($script:cardPanel.Children.Count -eq 0) 'Removed service still visible in panel.'

  # ---- 3. 同名重建，端口/URL 不同 ----
  $script:svc['X']=@{port=9090;url='http://127.0.0.1:9090/new'}
  Render-Page
  Assert ($script:cardPanel.Children.Count -eq 1) 'Rebuilt card not rendered.'
  $rebuilt=$script:cardPanel.Children[0]
  # 修前：命中缓存复用旧卡，Port=8080、Url=旧、Tag=旧（红）。
  # 修后：要么 cards 已清重建新卡，要么 Render-Page 命中缓存时刷新——两种路径都显示新值。
  Assert ($rebuilt.Port -eq 9090) "Port not refreshed after rebuild: got $($rebuilt.Port), expected 9090."
  Assert ($rebuilt.Url -eq 'http://127.0.0.1:9090/new') "Url not refreshed after rebuild: got $($rebuilt.Url)."
  # 打开面板按钮的 Tag 固化了 URL，是发现 1 自证的两路径不一致点之一
  $openBtn=$null
  foreach ($child in $rebuilt.Child.Children[3].Children) { if ($child.Content -eq '打开面板') { $openBtn=$child; break } }
  Assert ($openBtn.Tag -eq 'http://127.0.0.1:9090/new') "Open-panel Tag not refreshed: got $($openBtn.Tag)."

  # ---- 4. 不删除、只改端口（翻页回来命中缓存的刷新路径）----
  $script:svc['X']=@{port=7070;url='http://127.0.0.1:7070/v2'}
  Render-Page
  $refreshed=$script:cardPanel.Children[0]
  Assert ($refreshed.Port -eq 7070 -and $refreshed.Url -eq 'http://127.0.0.1:7070/v2') "In-place port change not refreshed on cache hit: Port=$($refreshed.Port) Url=$($refreshed.Url)."

  Write-Output 'PASS: removed card cache cleared and rebuilt card shows new port/URL/Tag.'
} finally { $win.Close(); $script:sync.wake.Dispose() }
