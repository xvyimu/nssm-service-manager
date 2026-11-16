#requires -Version 7.0
# 诊断脚本的阈值必须从 config 读：硬编码会在改默认值后悄悄失真，
# 而 probe-1053-timing.ps1 不进 run-all 的回归收集，失真没有任何红灯能发现。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-helpers.ps1')

$probePath = Join-Path $RepoRoot 'tests/probe-1053-timing.ps1'
$src = [IO.File]::ReadAllText($probePath)
$code = Get-SourceCodeOnly $src

Assert ($code -notmatch '\b45000\b') 'probe-1053 不得硬编码 ToggleTimeoutMs(45000)：应读 lib/config.ps1'
Assert ($code -notmatch '\b12000\b') 'probe-1053 不得硬编码停止预算(12000)：应读 lib/config.ps1'
Assert ($code -match 'config\.ps1') 'probe-1053 必须点源 lib/config.ps1 取阈值'
Assert ($code -match '\$script:config\.ToggleTimeoutMs') 'probe-1053 应直接读 $script:config.ToggleTimeoutMs'
Assert ($code -match '\$script:config\.WaitStoppedTimeoutMs') 'probe-1053 应直接读 $script:config.WaitStoppedTimeoutMs'

# 静态检查默认值的存在性：不点源 config（那会读本机 config.json，测试就不 hermetic）。
$cfgSrc = Get-SourceCodeOnly ([IO.File]::ReadAllText((Join-Path $RepoRoot 'lib/config.ps1')))
Assert ($cfgSrc -match 'ToggleTimeoutMs\s*=\s*\d+') 'lib/config.ps1 必须定义 ToggleTimeoutMs 默认值'

Write-Output 'PASS: probe-1053 thresholds come from lib/config.ps1 (no hardcoded 45000/12000).'
