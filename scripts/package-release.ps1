#requires -Version 7.0
# 打发布包：dist/service-manager-<VERSION>.zip
#
# 只装运行所需文件：主入口 + lib + 独立脚本 + example 配置 + README/LICENSE/VERSION。
# **不含** services.json / config.json / logs / tests —— 清单与实配属于用户本机，打进包里等于把
# 别人的服务列表发出去（这两个文件本来就 gitignore）。
# 不做安装器：管理员权限是 NSSM 本身的要求（sc.exe / 服务控制），不是安装包能解决的。
param(
  [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
  [string]$OutDir
)
$ErrorActionPreference = 'Stop'
$version = (Get-Content -LiteralPath (Join-Path $RepoRoot 'VERSION') -Raw -Encoding UTF8).Trim()
if (-not $version) { throw 'VERSION 文件为空' }
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot 'dist' }
$stage = Join-Path ([IO.Path]::GetTempPath()) "sm-pkg-$([guid]::NewGuid().ToString('N'))"
try {
  New-Item -ItemType Directory -Force $stage, $OutDir | Out-Null
  foreach ($f in 'service-manager-gui.ps1', 'launch.vbs', 'README.md', 'LICENSE', 'VERSION',
                 'config.example.json', 'services.example.json') {
    Copy-Item -LiteralPath (Join-Path $RepoRoot $f) -Destination $stage -Force
  }
  foreach ($d in 'lib', 'scripts') {
    Copy-Item -LiteralPath (Join-Path $RepoRoot $d) -Destination (Join-Path $stage $d) -Recurse -Force
  }
  # 自检：主入口与每个 lib 模块都要在包里，缺一个就是打包漏了（解压后才会发现）
  foreach ($must in 'service-manager-gui.ps1', 'lib\config.ps1', 'lib\util.ps1', 'lib\card.ps1') {
    if (-not (Test-Path -LiteralPath (Join-Path $stage $must))) { throw "打包缺文件：$must" }
  }
  $zip = Join-Path $OutDir "service-manager-$version.zip"
  if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
  Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal
  $size = [math]::Round((Get-Item -LiteralPath $zip).Length / 1KB, 1)
  Write-Host "已生成 $zip（${size} KB）"
  $zip
} finally {
  Remove-Item -LiteralPath $stage -Recurse -Force -EA SilentlyContinue
}
