#requires -Version 7.0
# 静态分析：CI 与本地同一条命令（pwsh -NoProfile -File tests/analyze.ps1）。
# 规则集与每条豁免的理由在 PSScriptAnalyzerSettings.psd1；有 Error/Warning 就 exit 1。
# 不叫 test-*.ps1：run-all.ps1 会通配收集，而本检查需要 PSScriptAnalyzer 模块，不该拖累回归测试。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
  Write-Output 'PSScriptAnalyzer 未安装：Install-Module PSScriptAnalyzer -Scope CurrentUser'
  exit 2
}
Import-Module PSScriptAnalyzer -ErrorAction Stop
$settings = Join-Path $RepoRoot 'PSScriptAnalyzerSettings.psd1'
$findings = @(Invoke-ScriptAnalyzer -Path $RepoRoot -Recurse -Settings $settings |
  Where-Object { $_.Severity -in @('Error', 'Warning') })
if ($findings.Count) {
  $findings | Sort-Object ScriptName, Line |
    Format-Table RuleName, ScriptName, Line, Message -AutoSize -Wrap | Out-String | Write-Output
  Write-Output "FAIL: $($findings.Count) PSScriptAnalyzer finding(s)."
  exit 1
}
Write-Output 'PASS: PSScriptAnalyzer clean (Error/Warning, settings: PSScriptAnalyzerSettings.psd1).'
