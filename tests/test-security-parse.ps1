$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib/util.ps1')

# 直接调用 Resolve-ServiceExeDir——不再复制逻辑，测试指向真实函数。
$cases = @(
  @{ Path = '';                       ExpectDir = '';                         ExpectQuoted = $false }
  @{ Path = 'nopath';                 ExpectDir = '';                         ExpectQuoted = $false }
  @{ Path = 'C:\app\server.exe';      ExpectDir = 'C:\app';                   ExpectQuoted = $false }
  @{ Path = '"' + 'C:\app\server.exe' + '"';              ExpectDir = 'C:\app';           ExpectQuoted = $true }
  @{ Path = '"' + 'C:\Program Files\app\server.exe' + '" -port 8080'; ExpectDir = 'C:\Program Files\app'; ExpectQuoted = $true }
  @{ Path = 'C:\app\server.exe -port 8080';               ExpectDir = 'C:\app';           ExpectQuoted = $false }
)

foreach ($c in $cases) {
  $r = Resolve-ServiceExeDir $c.Path
  $ok = ($r.dir -eq $c.ExpectDir) -and ($r.quoted -eq $c.ExpectQuoted)
  if (-not $ok) {
    throw "Path parse mismatch for [$($c.Path)]: got dir=[$($r.dir)] quoted=$($r.quoted), expected dir=[$($c.ExpectDir)] quoted=$($c.ExpectQuoted)"
  }
}
Write-Output 'PASS: Resolve-ServiceExeDir handles empty, bare, simple, quoted, spaced, and args cases without throwing.'
