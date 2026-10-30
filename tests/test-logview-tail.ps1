#requires -Version 7.0
# 日志查看器只读尾部：整文件读会卡住 UI 线程（NSSM 日志没有上限）。
# 修前 Show-Log 在点击时同步 [IO.File]::ReadLines 整个文件，且无 catch。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'lib/logview.ps1')
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }

$dir = Join-Path ([IO.Path]::GetTempPath()) "sm-tail-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force $dir | Out-Null
$file = Join-Path $dir 'Svc.out.log'
try {
  # 约 4MB：前 4000 行是填充，尾部 600 行带序号
  $sb = [Text.StringBuilder]::new()
  for ($i = 0; $i -lt 4000; $i++) { [void]$sb.AppendLine("filler line $i " + ('x' * 900)) }
  for ($i = 0; $i -lt 600; $i++) { [void]$sb.AppendLine("tail line $i") }
  [IO.File]::WriteAllText($file, $sb.ToString(), [Text.UTF8Encoding]::new($false))
  $size = (Get-Item -LiteralPath $file).Length

  $sw = [Diagnostics.Stopwatch]::StartNew()
  $text = Read-LogTail $file 500
  $sw.Stop()

  Assert ($null -ne $text -and $text.Length -gt 0) '应读到内容'
  Assert ($text.Length -lt 300000) "只应读尾部：got $($text.Length) 字符（整文件 $size 字节）"
  Assert ($text -match 'tail line 599') '应包含最后一行'
  Assert (-not ($text -match 'filler line 0 ')) '不该把文件头部读进来'
  $lines = @($text -split "`r?`n")
  Assert ($lines.Count -le 500) "最多 500 行，got $($lines.Count)"
  $nonEmpty = @($lines | Where-Object { $_ -ne '' })
  Assert ($nonEmpty[-1] -eq 'tail line 599') "最后一行应为 tail line 599，got [$($nonEmpty[-1])]"
  Assert ($sw.ElapsedMilliseconds -lt 1500) "读尾部应很快，got $($sw.ElapsedMilliseconds)ms"

  # 缺文件 → $null（调用方显示「无日志」），目录 → 也当缺失
  Assert ($null -eq (Read-LogTail (Join-Path $dir 'nope.log') 500)) '不存在的文件应返回 $null'
  Assert ($null -eq (Read-LogTail $dir 500)) '目录不是日志文件，应返回 $null'

  # 小文件（不足尾部窗口）整份读出，且不丢首行
  $small = Join-Path $dir 'Small.out.log'
  [IO.File]::WriteAllText($small, "a`r`nb`r`nc", [Text.UTF8Encoding]::new($false))
  Assert ((Read-LogTail $small 500) -eq "a`r`nb`r`nc") '小文件应原样返回（不丢行、不改行尾）'
} finally {
  Remove-Item -LiteralPath $dir -Recurse -Force -EA SilentlyContinue
}

Write-Output 'PASS: 日志只读尾部 256KB/500 行；小文件原样返回；缺失与目录返回 $null。'
