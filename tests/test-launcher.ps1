#requires -Version 7.0
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'

# Compile the real launcher with an early exit: no COM activation or UAC prompt.
$source = [IO.File]::ReadAllText((Join-Path $RepoRoot 'launch.vbs'))
$probe = Join-Path ([IO.Path]::GetTempPath()) "service-manager-launch-$([guid]::NewGuid().ToString('N')).vbs"
try {
  if ($source -notmatch '(?m)^Option Explicit\r?$') { throw 'Launcher must declare Option Explicit.' }
  $guarded = $source -replace '(?m)^Option Explicit\r?$', "Option Explicit`r`nWScript.Quit 0"
  [IO.File]::WriteAllText($probe, $guarded, [Text.UTF8Encoding]::new($false))
  & "$env:WINDIR\System32\cscript.exe" //Nologo $probe
  if ($LASTEXITCODE -ne 0) { throw "VBScript compilation failed (exit $LASTEXITCODE)." }
  if (@([IO.File]::ReadAllBytes((Join-Path $RepoRoot 'launch.vbs')) | Where-Object { $_ -gt 127 }).Count) {
    throw 'Launcher must remain ASCII for Windows Script Host ANSI decoding.'
  }
  Write-Output 'PASS: launcher compiles without executing elevation and contains only ASCII.'
} finally {
  if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe }
}
