#requires -Version 7.0
# scripts/deploy-local.ps1 — 把程序部署到管理员独占目录，并固定 NSSM 路径
#
# 为什么需要这一步：GUI 以管理员运行。程序、lib 脚本、nssm.exe 若放在用户可写目录，
# 任何标准用户改一行脚本，你下次双击并同意 UAC 就执行了它。ACL 是唯一真实的边界，
# 应用内自检只能「装错能被发现」，不构成防护。
#
# 用法（管理员）：
#   pwsh -NoProfile -File scripts/deploy-local.ps1
#   pwsh -NoProfile -File scripts/deploy-local.ps1 -Target 'D:\Apps\ServiceManager'
#
# 幂等：重复运行会覆盖程序文件，**不覆盖**目标已有的 services.json / config.json / logs。
param(
  [string]$SourceRoot = (Split-Path $PSScriptRoot -Parent),
  [string]$Target = (Join-Path $env:ProgramFiles 'ServiceManager')
)

$ErrorActionPreference = 'Stop'

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host '需要管理员权限：请从管理员 PowerShell 运行，或右键「以管理员身份运行」。'
  exit 2
}

function Set-AdminOnlyAcl([string]$path) {
  # 顺序有讲究：先 /reset /T 把复制进来的文件自带的显式 ACE 清掉（它们会盖住继承），
  # 再断目录继承、最后写显式规则——若先 grant 再 reset，reset 会把目录自身的显式规则一起重置回
  # 从父目录继承，等于白设（换到父目录本来就宽的目标路径时尤其危险）。
  & icacls.exe $path /reset /T /C /Q | Out-Null
  & icacls.exe $path /inheritance:r | Out-Null
  & icacls.exe $path /grant:r 'BUILTIN\Administrators:(OI)(CI)F' 'NT AUTHORITY\SYSTEM:(OI)(CI)F' 'BUILTIN\Users:(OI)(CI)RX' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "设置 ACL 失败：$path（icacls exit=$LASTEXITCODE）" }
}

function Copy-IfExists([string]$from, [string]$toDir) {
  if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination $toDir -Force }
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

foreach ($f in 'service-manager-gui.ps1','launch.vbs','VERSION','README.md','LICENSE','config.example.json','services.example.json') {
  Copy-IfExists (Join-Path $SourceRoot $f) $Target
}
foreach ($d in 'lib','scripts','assets') {
  $src = Join-Path $SourceRoot $d
  if (-not (Test-Path -LiteralPath $src)) { continue }
  $dst = Join-Path $Target $d
  New-Item -ItemType Directory -Force -Path $dst | Out-Null
  Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force
}

# 本机实配只在目标缺失时迁移一次：重复部署不能把用户的清单盖回源仓版本。
foreach ($f in 'services.json','config.json') {
  $src = Join-Path $SourceRoot $f
  $dst = Join-Path $Target $f
  if ((Test-Path -LiteralPath $src) -and -not (Test-Path -LiteralPath $dst)) {
    Copy-Item -LiteralPath $src -Destination $dst -Force
    Write-Host "已迁移本机配置：$f"
  }
}

Set-AdminOnlyAcl $Target
Write-Host "程序目录 ACL：Administrators/SYSTEM 完全控制，Users 只读执行"

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
foreach ($must in 'service-manager-gui.ps1','launch.vbs','lib\config.ps1','lib\util.ps1','lib\card.ps1','assets\icon.ico') {
  if (-not (Test-Path -LiteralPath (Join-Path $Target $must))) { $missing += $must }
}
if ($missing.Count) { throw "部署不完整，缺：$($missing -join ', ')" }
if (-not (Test-Path -LiteralPath $nssmTarget)) { throw "NSSM 未就位：$nssmTarget" }

$acl = Get-Acl -LiteralPath $Target
$broad = @($acl.Access | Where-Object {
  $_.AccessControlType -eq 'Allow' -and
  ($_.IdentityReference.Value -match 'Users|Authenticated Users|Everyone') -and
  ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write)
})
if ($broad.Count) { throw "ACL 自检失败：仍有 $($broad.Count) 条普通用户写权限" }

Write-Host ''
Write-Host '部署完成。'
Write-Host "  程序：$Target"
Write-Host "  入口：$Target\launch.vbs"
Write-Host "  NSSM：$nssmTarget"
Write-Host ''
Write-Host '把快捷方式指向新的 launch.vbs 即可；源仓保留为开发副本。'
