# lib/security-check.ps1 — 提权边界自检：exe 目录可写性 + 引号 + ACL 宽面判定
#
# 只做启发式告警（见 docs/HANDOFF.md），真正的边界是 deploy-local.ps1 设的 ACL。
# 由 lib/util.ps1 聚合加载。
# 主体/权限判据在 lib/acl.ps1（与注册表收紧脚本、部署门禁共用一份名单）。
if (-not (Get-Command Test-WidePrincipal -EA SilentlyContinue)) { . (Join-Path $PSScriptRoot 'acl.ps1') }

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

# 判定目录 ACL 是否「过宽」（本机任意标准用户可写）。返回 '是' / '否' / '未知（无法读取 ACL）'。§Test-DirAclPermissive
function Test-DirAclPermissive($acl){
  # 判据在 lib/acl.ps1：主体名单 + 写权限，与 set-service-params-acl.ps1、deploy-local.ps1 共用。§Test-AclHasWideWrite
  $r = Test-AclHasWideWrite $acl
  if ($null -eq $r) { return '未知（无法读取 ACL）' }
  if ($r) { return '是' }
  '否'
}

# 汇总多个目标的三态判定，供入口与测试共用。
# -AclProvider 可注入（默认真读 ACL）：测试用桩就能覆盖「读不到 / 抛错 / 可写」三种结果，
# 不必再靠正则去断言入口脚本里的字面量——那种断言写注释都能满足。
function Get-SecurityVerdicts($Targets, [scriptblock]$AclProvider = { param($p) Get-Acl -LiteralPath $p -EA Stop }){
  $findings = @(); $unknown = @()
  foreach ($key in $Targets.Keys) {
    $path = [string]$Targets[$key]
    if (-not $path) { $unknown += "$key 的路径未解析"; continue }
    if (-not (Test-Path -LiteralPath $path)) { $unknown += "$key 不存在：$path"; continue }
    $verdict = try { Test-DirAclPermissive (& $AclProvider $path) } catch { "异常：$($_.Exception.Message)" }
    if ($verdict -eq '是') { $findings += "$key 可被普通用户写入：$path" }
    elseif ($verdict -ne '否') { $unknown += "$key 的 ACL 无法判定：$path" }
  }
  @{ Findings = $findings; Unknown = $unknown }
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
  # 三态：定位不到目录、目录不存在、读不到 ACL 都属于「未知」，不能默认成「否（安全）」——
  # 那正是把「没检查」印成「检查过且没问题」。只有判据明确返回 '否' 才算不宽。
  $permissive =
    if (-not $dir) { '未知（无法定位目录）' }
    elseif (-not (Test-Path -LiteralPath $dir)) { '未知（目录不存在）' }
    else { try { Test-DirAclPermissive (Get-Acl -LiteralPath $dir -EA Stop) } catch { '未知（无法读取 ACL）' } }
  $qTxt = if($quoted){'是（已加固）'}else{'否（路径含空格时有提权风险）'}
  $msg = "$n`n`n路径: $path`n`n引号加固: $qTxt`n目录: $dir`n目录 ACL 过宽: $permissive"
  [System.Windows.MessageBox]::Show($msg,"$n 安全检查",'OK',$(if($quoted -and $permissive -eq '否'){'Information'}else{'Warning'})) | Out-Null
}
