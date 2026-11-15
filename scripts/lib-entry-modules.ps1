# scripts/lib-entry-modules.ps1 — 部署与打包共用的入口解析及纯文件完整性校验
# 解析器返回匹配项（可为空）；完整性断言成功无输出，失败抛错，不执行任何模块。
function Get-EntryLibModules([string]$entryText) {
  if ([string]::IsNullOrWhiteSpace($entryText)) { return @() }
  @([regex]::Matches($entryText, '(?m)^\s*\.\s+"\$root\\(lib\\[^"]+\.ps1)"') |
      ForEach-Object { $_.Groups[1].Value })
}

function Assert-EntryLibFiles([string]$SourceRoot, [string]$TargetRoot) {
  $entryText = Get-Content -LiteralPath (Join-Path $TargetRoot 'service-manager-gui.ps1') -Raw -Encoding UTF8 -ErrorAction Stop
  $entryModules = @(Get-EntryLibModules $entryText)
  if (-not $entryModules.Count) { throw '未能从 service-manager-gui.ps1 解析出 lib 模块 dot-source 列表' }
  # 间接加载模块不在入口里；以源 lib 全集补齐，新增模块自动参与校验。
  $libModules = @(Get-ChildItem -LiteralPath (Join-Path $SourceRoot 'lib') -Filter *.ps1 -Recurse -File -ErrorAction Stop |
      ForEach-Object { [IO.Path]::GetRelativePath($SourceRoot, $_.FullName) })
  $required = @('service-manager-gui.ps1', 'launch.vbs', 'assets\icon.ico') + $entryModules + $libModules
  $missing = @($required | Sort-Object -Unique | Where-Object {
      -not (Test-Path -LiteralPath (Join-Path $TargetRoot $_) -PathType Leaf -ErrorAction Stop)
    })
  if ($missing.Count) { throw "程序文件不完整，缺：$($missing -join ', ')" }
}
