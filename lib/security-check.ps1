# lib/security-check.ps1 — 提权边界自检：exe 目录可写性 + 引号 + ACL 宽面判定
#
# 只做启发式告警（见 docs/HANDOFF.md），真正的边界是 deploy-local.ps1 设的 ACL。
# 由 lib/util.ps1 聚合加载。

# ---- 安全检查（借鉴 PSSM：路径引号加固 + 目录 ACL 过宽）：纯解析，不碰 UI 也不抛错。§Resolve-ServiceExeDir
function Resolve-ServiceExeDir([string]$path){
  if (-not $path) { return @{ dir = ''; quoted = $false } }
  $quoted = $path.StartsWith('"')
  # 去首尾引号，匹配到首个 .exe 的路径段，取父路径
  $clean = $path.Trim('"')
  if ($clean -match '^[a-zA-Z]:\\.*?\.exe') { $clean = $matches[0] }
  elseif ($clean.Contains(' ')) { $clean = ($clean -split '(?<=\.exe)\s')[0] }
  $dir = if ($clean) { try { Split-Path $clean -Parent -EA Stop } catch { '' } } else { '' }
  @{ dir = $dir; quoted = $quoted }
}

# 判定目录 ACL 是否「过宽」（本机任意标准用户可写）。返回 '是' / '否' / '未知'。§Test-DirAclPermissive
function Test-DirAclPermissive($acl){
  if (-not $acl) { return '未知（无法读取 ACL）' }
  # 宽泛主体含 Authenticated Users 与 AppContainer SID（S-1-15-3-*）；判据与 set-service-params-acl.ps1 的 Test-LeakyAce 对齐。§Test-DirAclPermissive
  foreach ($a in $acl.Access) {
    $id = $a.IdentityReference.Value
    $wide = @('BUILTIN\Users','Everyone','Users','NT AUTHORITY\Authenticated Users','Authenticated Users') -contains $id -or $id -like 'S-1-15-3-*'
    if ($wide -and $a.FileSystemRights.ToString() -match 'Write|Modify|FullControl') { return '是' }
  }
  '否'
}

function Show-SecurityCheck([string]$n){
  # 名字要拼进 WQL 过滤器：services.json 里的名字没过 Test-SvcInput 的正则，
  # 带单引号的名字能把过滤器改成别的查询，安全检查就会给出错误的路径与 ACL 结论。
  if ($n -notmatch '^[A-Za-z0-9_.-]+$') {
    [System.Windows.MessageBox]::Show("服务名含非法字符，无法安全检查：$n",'错误','OK','Error') | Out-Null
    return
  }
  try {
    $ci = Get-CimInstance Win32_Service -Filter "Name='$n'" -EA Stop
  } catch {
    [System.Windows.MessageBox]::Show("无法查询 $n 的服务信息。`n$($_.Exception.Message)",'错误','OK','Error') | Out-Null
    return
  }
  $path = [string]$ci.PathName
  if (-not $path) {
    [System.Windows.MessageBox]::Show("无法读取 $n 的可执行路径。",'错误','OK','Error') | Out-Null
    return
  }
  $r = Resolve-ServiceExeDir $path
  $dir = $r.dir; $quoted = $r.quoted
  $permissive = '否'
  if ($dir -and (Test-Path $dir)) {
    try { $permissive = Test-DirAclPermissive (Get-Acl -Path $dir) }
    catch { $permissive = '未知（无法读取 ACL）' }
  }
  $qTxt = if($quoted){'是（已加固）'}else{'否（路径含空格时有提权风险）'}
  $msg = "$n`n`n路径: $path`n`n引号加固: $qTxt`n目录: $dir`n目录 ACL 过宽: $permissive"
  [System.Windows.MessageBox]::Show($msg,"$n 安全检查",'OK',$(if($quoted -and $permissive -eq '否'){'Information'}else{'Warning'})) | Out-Null
}
