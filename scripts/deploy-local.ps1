#requires -Version 7.0
# scripts/deploy-local.ps1 — 一键部署：自提权 → 备份 → 复制 → 校验 → 启动
#
# 为什么需要这一步：GUI 以管理员运行。程序、lib 脚本、nssm.exe 若放在用户可写目录，
# 任何标准用户改一行脚本，你下次双击并同意 UAC 就执行了它。ACL 是唯一真实的边界，
# 应用内自检只能「装错能被发现」，不构成防护。
#
# 用法（普通权限即可，脚本自己弹一次 UAC 再重跑）：
#   pwsh -NoProfile -File scripts/deploy-local.ps1
#   pwsh -NoProfile -File scripts/deploy-local.ps1 -NoLaunch          # 只部署不启动
#   pwsh -NoProfile -File scripts/deploy-local.ps1 -Target 'D:\Apps\ServiceManager'
#
# 幂等：重复运行覆盖程序文件，**不覆盖**目标已有的 services.json / config.json / logs。
# 覆盖前把旧程序文件整份备份到 %ProgramData%\ServiceManager\backup\<时间戳>\（留最近 5 份），
# 复制完逐文件比对 SHA256；失败时恢复程序文件，还原失败会明确列出路径。
param(
  [string]$SourceRoot = (Split-Path $PSScriptRoot -Parent),
  [string]$Target = (Join-Path $env:ProgramFiles 'ServiceManager'),
  [switch]$NoLaunch,
  [string]$LogPath = (Join-Path $env:LOCALAPPDATA 'ServiceManager\deploy.log')
)

$ErrorActionPreference = 'Stop'

# 随程序一起走、需要校验的条目：改这里就同时改了「复制 / 备份 / 校验」三处。
# 与 scripts/package-release.ps1 的复制清单刻意不共享：部署要整目录覆盖（含 scripts/、assets/ 全量）
# 且带 README/VERSION 便于现场查看；打包只取运行所需 + assets/icon.ico。语义不同，合并会互相牵制。
$FileList = 'service-manager-gui.ps1', 'launch.vbs', 'VERSION', 'README.md', 'LICENSE', 'config.example.json', 'services.example.json'
$DirList = 'lib', 'scripts', 'assets'

function Set-AdminOnlyAcl([string]$path) {
  # 顺序有讲究：先 /reset /T 把复制进来的文件自带的显式 ACE 清掉（它们会盖住继承），
  # 再断目录继承、最后写显式规则——若先 grant 再 reset，reset 会把目录自身的显式规则一起重置回
  # 从父目录继承，等于白设（换到父目录本来就宽的目标路径时尤其危险）。
  # 不加 /C：被占用的文件会让 reset 半途而废，静默跳过等于留下旧宽松 ACE，宁可整体失败。
  & icacls.exe $path /reset /T /Q | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "重置 ACL 失败：$path（icacls exit=$LASTEXITCODE，可能有文件被占用）" }
  & icacls.exe $path /inheritance:r | Out-Null
  & icacls.exe $path /grant:r 'BUILTIN\Administrators:(OI)(CI)F' 'NT AUTHORITY\SYSTEM:(OI)(CI)F' 'BUILTIN\Users:(OI)(CI)RX' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "设置 ACL 失败：$path（icacls exit=$LASTEXITCODE）" }
}

# 某目录下「参与部署」的相对路径清单（源侧用它算要复制什么）。
function Get-DeployFiles([string]$root) {
  $root = $root.TrimEnd('\', '/')
  $list = @()
  foreach ($f in $FileList) {
    if (Test-Path -LiteralPath (Join-Path $root $f)) { $list += $f }
  }
  foreach ($d in $DirList) {
    $dir = Join-Path $root $d
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    foreach ($item in Get-ChildItem -LiteralPath $dir -Recurse -File) {
      $list += [IO.Path]::GetRelativePath($root, $item.FullName)
    }
  }
  $list
}

# 恢复尝试过的程序文件；没有旧备份的文件是本轮新增，回收到回收站。
function Restore-Backup([string[]]$paths, [string]$backupDir, [string]$targetDir) {
  $failed = @()
  $targetPrefix = [IO.Path]::GetFullPath($targetDir).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
  foreach ($f in $paths) {
    $src = Join-Path $backupDir $f
    $dst = [IO.Path]::GetFullPath((Join-Path $targetDir $f))
    try {
      if (-not $dst.StartsWith($targetPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "还原路径不在目标目录内：$f" }
      if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $dst -Force }
      elseif (Test-Path -LiteralPath $dst) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($dst, 'OnlyErrorDialogs', 'SendToRecycleBin') }
    } catch { $failed += "$f：$($_.Exception.Message)" }
  }
  $failed
}

function Invoke-DeployFiles([string]$SourceRoot, [string]$Target, [string]$backup, [string[]]$files, [scriptblock]$Complete) {
  $attempted = @()
  try {
    foreach ($f in $files) {
      $dst = Join-Path $Target $f
      New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
      # Copy-Item 可能在改写目标后抛错，所以在复制前登记当前文件。
      $attempted += $f
      Copy-Item -LiteralPath (Join-Path $SourceRoot $f) -Destination $dst -Force
    }
    foreach ($f in $files) {
      $h1 = (Get-FileHash -LiteralPath (Join-Path $SourceRoot $f) -Algorithm SHA256).Hash
      $h2 = (Get-FileHash -LiteralPath (Join-Path $Target $f) -Algorithm SHA256).Hash
      if ($h1 -ne $h2) { throw "复制校验失败（内容不一致）：$f" }
    }
    # 仅退役已被无窗口入口取代的旧启动器；其它旧文件仍保留。
    $retired = 'scripts\deploy.cmd'
    $retiredPath = [IO.Path]::GetFullPath((Join-Path $Target $retired))
    if (Test-Path -LiteralPath $retiredPath) {
      $targetPrefix = [IO.Path]::GetFullPath($Target).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
      if (-not $retiredPath.StartsWith($targetPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw '旧入口退役路径超出部署目标' }
      $attempted += $retired
      [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($retiredPath, 'OnlyErrorDialogs', 'SendToRecycleBin')
    }
    & $Complete
  } catch {
    $failure = $_
    $restoreFailures = @(Restore-Backup $attempted $backup $Target)
    if ($restoreFailures.Count) { throw "部署失败：$($failure.Exception.Message)。程序文件还原失败：$($restoreFailures -join '；')。备份：$backup" }
    throw "部署失败，程序文件已还原；权限及 NSSM 安装状态不回退。原因：$($failure.Exception.Message)。备份：$backup"
  }
}

function Get-NssmSource([string]$nssmTarget) {
  if (Test-Path -LiteralPath $nssmTarget) { return $null }
  $cmd = Get-Command nssm.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $scoop = Join-Path $env:USERPROFILE 'scoop\apps\nssm\current\nssm.exe'
  if (Test-Path -LiteralPath $scoop) { return $scoop }
  throw '未找到 nssm.exe：先 scoop install nssm，再重跑部署；程序文件未改变。'
}

# -- 自提权：普通权限下用 UAC 重跑自己，退出码带回来 -------------------------------
if (-not $PSCommandPath) { throw '拿不到脚本路径：请用 -File 方式运行本脚本。' }
# 提权后的子进程工作目录是 system32，相对路径会解析到别处：先转绝对路径再传参数。
$SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).ProviderPath
if (-not [IO.Path]::IsPathRooted($Target)) { $Target = Join-Path (Get-Location).ProviderPath $Target }
$Target = [IO.Path]::GetFullPath($Target)
New-Item -ItemType Directory -Force -Path (Split-Path $LogPath -Parent) | Out-Null

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  $quote = { param($v) '"' + ($v -replace '"', '') + '"' }
  [IO.File]::WriteAllText($LogPath, '', [Text.UTF8Encoding]::new($false))
  $argList = @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-File', (& $quote $PSCommandPath), '-SourceRoot', (& $quote $SourceRoot), '-Target', (& $quote $Target), '-LogPath', (& $quote $LogPath))
  if ($NoLaunch) { $argList += '-NoLaunch' }
  Write-Host '需要管理员权限，正在请求 UAC…'
  try {
    # 不用 -Wait：PowerShell 7.3 起它会等整棵进程树，而提权子进程最后会启动 GUI，
    # 于是部署入口（含 deploy.vbs）要等用户关掉窗口才返回，看起来像卡死。
    # 只等提权子进程自身结束，GUI 留在自己的进程树里继续跑。
    $child = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList ($argList -join ' ') -Verb RunAs -WindowStyle Hidden -PassThru
    $child.WaitForExit()
  } catch {
    [IO.File]::WriteAllText($LogPath, "提权被取消或失败：$($_.Exception.Message)", [Text.UTF8Encoding]::new($false))
    exit 2
  }
  exit $(if ($null -ne $child.ExitCode) { $child.ExitCode } else { 0 })
}
Start-Transcript -LiteralPath $LogPath -Force | Out-Null

if (-not (Test-Path -LiteralPath (Join-Path $SourceRoot 'service-manager-gui.ps1'))) {
  throw "源目录不像本程序：$SourceRoot"
}

# 先验证依赖再覆盖程序。缺 NSSM 时旧版保持原样。
$nssmTargetDir = Join-Path $env:ProgramFiles 'nssm'
$nssmTarget = Join-Path $nssmTargetDir 'nssm.exe'
$nssmSource = Get-NssmSource $nssmTarget

# 程序在跑时不能覆盖装机目录：GUI 持有 icon 等文件句柄，Copy-Item 会失败且报错不明确。
# 先查单实例 mutex（与程序同名），在跑就让人先退出，别让人对着 exit 1 猜。
try {
  $m = [Threading.Mutex]::OpenExisting('Global\service-manager-gui')
  $m.Dispose()
  Write-Host '检测到程序正在运行：请先退出（窗口 ✕ 或托盘「退出」），再重跑部署。'
  exit 4
} catch [System.Threading.WaitHandleCannotBeOpenedException] {
  # 没有实例持有 = 可以继续
}

Write-Host "部署到：$Target"
New-Item -ItemType Directory -Force -Path $Target | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Target 'logs') | Out-Null

$files = Get-DeployFiles $SourceRoot
# 完整性断言与打包共用；放在复制 try 之前定义，失败时由 catch 走还原。
. (Join-Path $PSScriptRoot 'lib-entry-modules.ps1')

# -- 备份旧程序文件（失败可整份搬回；配置与日志不备份，它们本来就不覆盖）-----------
# 目录全量备份，而不只是「源里还有的文件」：新版本删掉的旧模块也能回滚，避免版本漂移残留。
$backupRoot = Join-Path $env:ProgramData 'ServiceManager\backup'
$backup = Join-Path $backupRoot (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$old = @(Get-ChildItem -LiteralPath $Target -Recurse -File -Force | Where-Object {
    $rel = [IO.Path]::GetRelativePath($Target, $_.FullName)
    $rel -notmatch '^(logs|services\.json|config\.json)(\\|$)'
  } | ForEach-Object { [IO.Path]::GetRelativePath($Target, $_.FullName) })
foreach ($f in $old) {
  $dst = Join-Path $backup $f
  New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
  Copy-Item -LiteralPath (Join-Path $Target $f) -Destination $dst -Force
}
Get-ChildItem -LiteralPath $backupRoot -Directory -ErrorAction SilentlyContinue |
  Sort-Object Name -Descending | Select-Object -Skip 5 | ForEach-Object {
    $backupPrefix = [IO.Path]::GetFullPath($backupRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $_.FullName.StartsWith($backupPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw '备份清理路径超出备份目录' }
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($_.FullName, 'OnlyErrorDialogs', 'SendToRecycleBin')
  }
if ($old.Count) { Write-Host "已备份 $($old.Count) 个旧文件：$backup" }

# 文件恢复覆盖复制、校验、ACL 和依赖落地后的自检；权限设置本身不回退。
Invoke-DeployFiles $SourceRoot $Target $backup $files {
  Assert-EntryLibFiles -SourceRoot $SourceRoot -TargetRoot $Target
  Write-Host "已复制并校验 $($files.Count) 个文件（SHA256 一致）"

  # 新版本删掉的文件不会被自动清理（宁留勿删）：列出来，让人自己决定。
  $stale = @($old | Where-Object { $files -notcontains $_ -and $_ -ne 'scripts\deploy.cmd' })
  if ($stale.Count) { Write-Host "提示：这些旧文件新版本里已没有，保留未删：$($stale -join ', ')" }

  # 本机实配只在目标缺失时迁移一次：重复部署不能把用户的清单盖回源仓版本。
  foreach ($f in 'services.json', 'config.json') {
    $src = Join-Path $SourceRoot $f
    $dst = Join-Path $Target $f
    if ((Test-Path -LiteralPath $src) -and -not (Test-Path -LiteralPath $dst)) {
      Copy-Item -LiteralPath $src -Destination $dst -Force
      Write-Host "已迁移本机配置：$f"
    }
  }

  Set-AdminOnlyAcl $Target
  Write-Host '程序目录 ACL：Administrators/SYSTEM 完全控制，Users 只读执行'

  # NSSM 的可用来源已在覆盖程序前验证。
  if (-not (Test-Path -LiteralPath $nssmTarget)) {
    New-Item -ItemType Directory -Force -Path $nssmTargetDir | Out-Null
    Copy-Item -LiteralPath $nssmSource -Destination $nssmTarget -Force
    Write-Host "已固定 NSSM：$nssmSource -> $nssmTarget"
  } else {
    Write-Host "NSSM 已就位：$nssmTarget"
  }
  Set-AdminOnlyAcl $nssmTargetDir

  if (-not (Test-Path -LiteralPath $nssmTarget)) { throw "NSSM 未就位：$nssmTarget" }

  # 自检要递归：/reset /T 若因占用跳过某个子文件，只看根目录的 ACL 会漏掉它。
  # 主体/权限判据的唯一来源是 lib/acl.ps1（GUI 自检、注册表收紧脚本共用）；这份门禁曾只匹配
  # Users/Everyone，漏掉 AppContainer SID（S-1-15-3-*）。
  if (-not (Get-Command Test-WidePrincipal -EA SilentlyContinue)) { . (Join-Path $PSScriptRoot '..\lib\acl.ps1') }
  $broad = @()
  $unreadable = @()
  foreach ($item in Get-ChildItem -LiteralPath $Target -Recurse -Force) {
    $itemAcl = Get-Acl -LiteralPath $item.FullName
    # 门禁 fail-closed：判不出来（$null）也算不通过，但报错文案要分开——「读不到 ACL」和
    # 「还有普通用户写权限」是两种完全不同的排查方向。
    $wideWrite = Test-AclHasWideWrite $itemAcl
    if ($null -eq $wideWrite) { $unreadable += $item.FullName }
    elseif ($wideWrite) { $broad += $item.FullName }
  }
  if ($unreadable.Count) { throw "ACL 自检失败：$($unreadable.Count) 个条目的 ACL 读不出来（无法判定），例如 $($unreadable[0])" }
  if ($broad.Count) { throw "ACL 自检失败：$($broad.Count) 个条目仍有普通用户写权限，例如 $($broad[0])" }
}

$version = (Get-Content -LiteralPath (Join-Path $Target 'VERSION') -Raw -Encoding UTF8).Trim()
Write-Host ''
Write-Host "部署完成（v$version）：$Target"

if ($NoLaunch) {
  Write-Host '未启动（-NoLaunch）。双击 launch.vbs 打开。'
} else {
  Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$(Join-Path $Target 'launch.vbs')`"" -WindowStyle Hidden | Out-Null
  Write-Host '已启动服务管理窗口（GUI 需要管理员，会弹一次 UAC）。'
}
Stop-Transcript | Out-Null
