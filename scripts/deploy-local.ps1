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
# 复制完逐文件比对 SHA256，不一致即失败——不会留下半新半旧的装机目录。
param(
  [string]$SourceRoot = (Split-Path $PSScriptRoot -Parent),
  [string]$Target = (Join-Path $env:ProgramFiles 'ServiceManager'),
  [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'

# 随程序一起走、需要校验的条目：改这里就同时改了「复制 / 备份 / 校验」三处。
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

# 复制/校验失败时把已覆盖的文件搬回原样。被占用的文件还原也会失败，那就只报路径让人手动来。
function Restore-Backup([string[]]$paths, [string]$backupDir, [string]$targetDir) {
  $failed = @()
  foreach ($f in $paths) {
    $src = Join-Path $backupDir $f
    if (-not (Test-Path -LiteralPath $src)) { continue }
    try { Copy-Item -LiteralPath $src -Destination (Join-Path $targetDir $f) -Force } catch { $failed += $f }
  }
  if ($failed.Count) { Write-Host "还原失败（文件被占用？）：$($failed -join ', ')" }
}

# -- 自提权：普通权限下用 UAC 重跑自己，退出码带回来 -------------------------------
if (-not $PSCommandPath) { throw '拿不到脚本路径：请用 -File 方式运行本脚本。' }
# 提权后的子进程工作目录是 system32，相对路径会解析到别处：先转绝对路径再传参数。
$SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).ProviderPath
if (-not [IO.Path]::IsPathRooted($Target)) { $Target = Join-Path (Get-Location).ProviderPath $Target }
$Target = [IO.Path]::GetFullPath($Target)

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  $quote = { param($v) '"' + ($v -replace '"', '') + '"' }
  $argList = @('-NoProfile', '-File', (& $quote $PSCommandPath), '-SourceRoot', (& $quote $SourceRoot), '-Target', (& $quote $Target))
  if ($NoLaunch) { $argList += '-NoLaunch' }
  Write-Host '需要管理员权限，正在请求 UAC…'
  try {
    $child = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList ($argList -join ' ') -Verb RunAs -Wait -PassThru
  } catch {
    Write-Host "提权被取消或失败：$($_.Exception.Message)"
    exit 2
  }
  exit $(if ($null -ne $child.ExitCode) { $child.ExitCode } else { 0 })
}

if (-not (Test-Path -LiteralPath (Join-Path $SourceRoot 'service-manager-gui.ps1'))) {
  throw "源目录不像本程序：$SourceRoot"
}

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
  Sort-Object Name -Descending | Select-Object -Skip 5 | Remove-Item -Recurse -Force
if ($old.Count) { Write-Host "已备份 $($old.Count) 个旧文件：$backup" }

# -- 复制 + 逐文件哈希校验（任何一步失败都先还原，不留半新半旧的装机目录）-----------
$copied = @()
try {
  foreach ($f in $files) {
    $dst = Join-Path $Target $f
    New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
    Copy-Item -LiteralPath (Join-Path $SourceRoot $f) -Destination $dst -Force
    $copied += $f
  }
  $mismatch = @()
  foreach ($f in $files) {
    $h1 = (Get-FileHash -LiteralPath (Join-Path $SourceRoot $f) -Algorithm SHA256).Hash
    $h2 = (Get-FileHash -LiteralPath (Join-Path $Target $f) -Algorithm SHA256).Hash
    if ($h1 -ne $h2) { $mismatch += $f }
  }
  if ($mismatch.Count) { throw "复制校验失败（内容不一致）：$($mismatch -join ', ')" }
} catch {
  Restore-Backup $copied $backup $Target
  Write-Host "部署失败，已按备份还原 $($copied.Count) 个文件。备份仍在：$backup"
  throw
}
Write-Host "已复制并校验 $($files.Count) 个文件（SHA256 一致）"

# 新版本删掉的文件不会被自动清理（宁留勿删）：列出来，让人自己决定。
$stale = @($old | Where-Object { $files -notcontains $_ })
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

# NSSM 固定到 Program Files：GUI 只认这个路径，不再读用户环境里的 NSSM_PATH/PATH。
$nssmTargetDir = Join-Path $env:ProgramFiles 'nssm'
$nssmTarget = Join-Path $nssmTargetDir 'nssm.exe'
if (-not (Test-Path -LiteralPath $nssmTarget)) {
  $source = $null
  $cmd = Get-Command nssm.exe -ErrorAction SilentlyContinue
  if ($cmd) { $source = $cmd.Source }
  if (-not $source) {
    $scoop = Join-Path $env:USERPROFILE 'scoop\apps\nssm\current\nssm.exe'
    if (Test-Path -LiteralPath $scoop) { $source = $scoop }
  }
  if (-not $source) {
    Write-Host '未找到 nssm.exe：先 scoop install nssm，再重跑本脚本。'
    exit 3
  }
  New-Item -ItemType Directory -Force -Path $nssmTargetDir | Out-Null
  Copy-Item -LiteralPath $source -Destination $nssmTarget -Force
  Write-Host "已固定 NSSM：$source -> $nssmTarget"
} else {
  Write-Host "NSSM 已就位：$nssmTarget"
}
Set-AdminOnlyAcl $nssmTargetDir

# 自检：程序文件齐全 + 标准用户不可写。
$missing = @()
foreach ($must in 'service-manager-gui.ps1', 'launch.vbs', 'lib\config.ps1', 'lib\util.ps1', 'lib\svc-store.ps1', 'lib\ui-status.ps1', 'lib\log-retention.ps1', 'lib\security-check.ps1', 'lib\shutdown.ps1', 'lib\card.ps1', 'assets\icon.ico') {
  if (-not (Test-Path -LiteralPath (Join-Path $Target $must))) { $missing += $must }
}
if ($missing.Count) { throw "部署不完整，缺：$($missing -join ', ')" }
if (-not (Test-Path -LiteralPath $nssmTarget)) { throw "NSSM 未就位：$nssmTarget" }

# 自检要递归：/reset /T 若因占用跳过某个子文件，只看根目录的 ACL 会漏掉它。
$broad = @()
foreach ($item in Get-ChildItem -LiteralPath $Target -Recurse -Force) {
  $itemAcl = Get-Acl -LiteralPath $item.FullName
  foreach ($ace in $itemAcl.Access) {
    if ($ace.AccessControlType -eq 'Allow' -and
      ($ace.IdentityReference.Value -match 'Users|Authenticated Users|Everyone') -and
      ($ace.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write)) {
      $broad += $item.FullName
      break
    }
  }
}
if ($broad.Count) { throw "ACL 自检失败：$($broad.Count) 个条目仍有普通用户写权限，例如 $($broad[0])" }

$version = (Get-Content -LiteralPath (Join-Path $Target 'VERSION') -Raw -Encoding UTF8).Trim()
Write-Host ''
Write-Host "部署完成（v$version）：$Target"

if ($NoLaunch) {
  Write-Host '未启动（-NoLaunch）。双击 launch.vbs 打开。'
} else {
  Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$(Join-Path $Target 'launch.vbs')`"" | Out-Null
  Write-Host '已启动服务管理窗口（GUI 需要管理员，会弹一次 UAC）。'
}
