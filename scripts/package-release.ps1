#requires -Version 7.0
# 打发布包：dist/service-manager-<VERSION>.zip
#
# 只装运行所需文件：主入口 + lib + 独立脚本 + example 配置 + README/LICENSE/VERSION + assets/icon.ico。
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
  # 图标只取 ico：assets 里还有 demo.gif / screenshot.png（README 展示用），不进发布包
  $icon = Join-Path $RepoRoot 'assets\icon.ico'
  if (-not (Test-Path -LiteralPath $icon)) { throw '打包缺文件：assets\icon.ico' }
  New-Item -ItemType Directory -Force (Join-Path $stage 'assets') | Out-Null
  Copy-Item -LiteralPath $icon -Destination (Join-Path $stage 'assets') -Force

  # 自检 1（正向）：清单从主入口的 dot-source 列表派生，新增 lib 模块自动被覆盖。
  # 解析不到任何项说明格式变了，必须 throw —— 否则退化成空检查，漏文件到解压才发现。
  $entry = Get-Content -LiteralPath (Join-Path $RepoRoot 'service-manager-gui.ps1') -Raw -Encoding UTF8
  $modules = @([regex]::Matches($entry, '(?m)^\s*\.\s+"\$root\\(lib\\[^"]+\.ps1)"') |
      ForEach-Object { $_.Groups[1].Value })
  if (-not $modules.Count) { throw '未能从 service-manager-gui.ps1 解析出 lib 模块 dot-source 列表' }
  foreach ($must in @('service-manager-gui.ps1') + $modules) {
    if (-not (Test-Path -LiteralPath (Join-Path $stage $must))) { throw "打包缺文件：$must" }
  }

  $zip = Join-Path $OutDir "service-manager-$version.zip"
  if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
  Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal

  # 自检 2（负向）：查真产物而不是 staging —— 实配清单 / 日志 / 测试绝不能进包
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = [IO.Compression.ZipFile]::OpenRead($zip)
  try {
    $names = @($archive.Entries | ForEach-Object { $_.FullName -replace '\\', '/' })
  } finally {
    $archive.Dispose()
  }
  $leaks = @($names | Where-Object { $_ -match '(^|/)(config|services)\.json$' -or $_ -match '^(logs|tests)/' })
  if ($leaks.Count) { throw "发布包含有本机清单或测试目录：$($leaks -join ', ')" }
  if ($names -notcontains 'assets/icon.ico') { throw '发布包缺 assets/icon.ico' }

  $size = [math]::Round((Get-Item -LiteralPath $zip).Length / 1KB, 1)
  Write-Host "已生成 $zip（${size} KB）"
  $zip
} finally {
  Remove-Item -LiteralPath $stage -Recurse -Force -EA SilentlyContinue
}
