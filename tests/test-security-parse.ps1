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
  # ---- 负例：以下都不应抛错，且应给出确定的（多为空）结果 ----
  @{ Path = '   ';                                         ExpectDir = '';                 ExpectQuoted = $false }  # 纯空白
  @{ Path = 'C:';                                          ExpectDir = '';                 ExpectQuoted = $false }  # 只有盘符
  @{ Path = 'C:\';                                         ExpectDir = '';                 ExpectQuoted = $false }  # 根目录，无文件名
  @{ Path = 'C:\app\server';                               ExpectDir = 'C:\app';           ExpectQuoted = $false }  # 无 .exe 扩展名仍取父目录
  @{ Path = 'notepad.exe';                                 ExpectDir = '';                 ExpectQuoted = $false }  # 裸文件名，无目录
  @{ Path = '"' + 'C:\app\server.exe';                     ExpectDir = 'C:\app';           ExpectQuoted = $true  }  # 引号不闭合
  @{ Path = '\\server\share\app.exe';                      ExpectDir = '\\server\share';   ExpectQuoted = $false }  # UNC 路径
  @{ Path = '"' + '\\server\share\my app\server.exe' + '" -x'; ExpectDir = '\\server\share\my app'; ExpectQuoted = $true }  # UNC + 空格 + 引号 + 参数
  @{ Path = 'C:/app/server.exe';                           ExpectDir = 'C:\app';           ExpectQuoted = $false }  # 正斜杠归一化
  @{ Path = 'C:\app\server.EXE';                           ExpectDir = 'C:\app';           ExpectQuoted = $false }  # 扩展名大小写不敏感
  @{ Path = '  C:\app\server.exe  ';                       ExpectDir = '  C:\app';         ExpectQuoted = $false }  # 前后空白不被 trim（当前行为）
)

foreach ($c in $cases) {
  $r = Resolve-ServiceExeDir $c.Path
  $ok = ($r.dir -eq $c.ExpectDir) -and ($r.quoted -eq $c.ExpectQuoted)
  if (-not $ok) {
    throw "Path parse mismatch for [$($c.Path)]: got dir=[$($r.dir)] quoted=$($r.quoted), expected dir=[$($c.ExpectDir)] quoted=$($c.ExpectQuoted)"
  }
}
Write-Output 'PASS: Resolve-ServiceExeDir handles empty, bare, simple, quoted, spaced, args, UNC, unclosed-quote, slash-normalized, and whitespace cases without throwing.'
