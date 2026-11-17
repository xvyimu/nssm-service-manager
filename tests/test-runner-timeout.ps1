#requires -Version 7.0
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-helpers.ps1')

# 执行总入口真实函数：挂起子进程必须被记成失败，随后测试仍能运行。
$ast = [Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $PSScriptRoot 'run-all.ps1'), [ref]$null, [ref]$null)
foreach ($name in 'Invoke-Check','Invoke-RegressionTest') {
  $definition = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
  }.GetNewClosure(), $true)
  Assert ($null -ne $definition) "$name is missing"
  . ([scriptblock]::Create($definition.Extent.Text))
}
$fixture = New-TestTempDir 'sm-runner-timeout'
try {
  $hanging = Join-Path $fixture 'hang.ps1'
  $passing = Join-Path $fixture 'pass.ps1'
  [IO.File]::WriteAllText($hanging, 'Start-Sleep -Seconds 30')
  [IO.File]::WriteAllText($passing, "Write-Output 'PASS: subsequent fixture ran'")
  $script:failures = @()
  # 点源进来的 Invoke-RegressionTest 从本文件作用域读这个变量；用 Set-Variable 明确是夹具配置，
  # 也避免 PSScriptAnalyzer 把它当成未使用的局部赋值。
  Set-Variable -Name TestTimeoutSeconds -Value 1 -Scope Script
  $clock = [Diagnostics.Stopwatch]::StartNew()
  $output = @(Invoke-Check 'hang' { Invoke-RegressionTest $hanging })
  $output += @(Invoke-Check 'after' { Invoke-RegressionTest $passing })
  Assert ($script:failures.Count -eq 1 -and $script:failures[0].Label -eq 'hang') 'Timeout must fail only the hanging test'
  Assert (($output -join "`n") -match 'subsequent fixture ran') 'Runner must continue after timeout'
  Assert ($clock.Elapsed.TotalSeconds -lt 8) 'Runner waited for the hanging fixture instead of stopping it'
  Write-Output 'PASS: hanging test fails within its deadline and the following test still runs'
} finally {
  if ((Resolve-Path -LiteralPath $fixture).Path -ne $fixture) { throw 'Unexpected fixture directory' }
  Add-Type -AssemblyName Microsoft.VisualBasic.Core
  [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($fixture, 'OnlyErrorDialogs', 'SendToRecycleBin')
}
