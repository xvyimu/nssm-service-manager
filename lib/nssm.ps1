# lib/nssm.ps1 — NSSM 操作包装：set / install / remove
#
# 从 lib/util.ps1（nssm-set）与 lib/add-svc.ps1（Install/Remove）合并抽出。
# 不含 UI、不含输入校验——纯 NSSM 命令包装，失败抛错。
# 作用域约定与自加载依赖：docs/IMPLEMENTATION-NOTES.md
. (Join-Path $PSScriptRoot 'svc-input.ps1')
. (Join-Path $PSScriptRoot 'svc-common.ps1')

# NSSM set 包装：失败抛错
function nssm-set([string]$n,[string]$k,[Parameter(ValueFromRemainingArguments=$true)][object[]]$v){
  # 经 Invoke-ExternalQuiet：nssm.exe 也是控制台程序，GUI 进程直接 `& nssm` 会弹黑框
  $r = Invoke-ExternalQuiet $script:nssm (@('set', $n, $k) + @($v))
  if($r.exit -ne 0){ throw "NSSM set $k 失败($($r.exit)): $($r.out)" }
}

# GUI/CLI 共用 NSSM 注册与配置；输入校验、错误显示、保存和启动仍由调用方处理。
function Install-NssmService([string]$n,[string]$exe,[string]$dir,[string]$par,$envPairs,[string]$account=''){
  $inst = Invoke-ExternalQuiet $script:nssm @('install', $n, $exe)
  $nssmOut = $inst.out
  if($inst.exit -ne 0){ throw "NSSM install 失败($($inst.exit)): $nssmOut" }
  # install 退出码不可信（提权不足时打印报错却返回 0），以「服务是否真出现」复核。§Install-NssmService
  if(-not (Test-ServicePresent $n)){
    $why = if(($nssmOut -join ' ') -match 'Administrator access'){ '需要管理员权限' } else { '服务未创建' }
    throw "NSSM install 未生效：$why"
  }
  # set 失败会留半注册残骸，失败时尽力 remove 回滚再抛原始错误；阈值从 config 取，缺则回落形参默认值（不靠 [int]$null=0）。
  $rotateBytes = if ($script:config -and $script:config.AppRotateBytes) { [int]$script:config.AppRotateBytes } else { 5242880 }
  $stopMethod  = if ($script:config -and $script:config.AppStopMethodConsole) { [int]$script:config.AppStopMethodConsole } else { 5000 }
  # 轮转年龄门槛：不设的话「每次启动轮转一次」会把频繁重启的服务的日志堆成几十个档
  $rotateSecs  = if ($script:config -and $script:config.AppRotateSeconds) { [int]$script:config.AppRotateSeconds } else { 86400 }
  try {
    foreach($s in Get-NssmSetSpec $n $dir $par $envPairs $rotateBytes $stopMethod $account $rotateSecs){ nssm-set $n $s.k $s.v }
  } catch {
    # 回滚失败不盖掉原始错误，但也不能静默——残骸服务还留在服务数据库里，用户需要知道。
    try {
      [void](Invoke-ExternalQuiet $script:nssm @('remove', $n, 'confirm'))
      if(-not (Test-ServiceGone $n)){
        Write-Warning "回滚未生效：$n 可能仍残留在服务数据库，请手动 nssm remove $n confirm"
      }
    } catch { Write-Warning "回滚失败：$n 可能仍残留在服务数据库（$($_.Exception.Message)）" }
    throw
  }
}

# 删除 NSSM 服务（同步、失败抛异常）；序列本体在 svc-common.ps1。无生产调用方是有意保留，死代码扫描请勿删。§Remove-NssmService
function Remove-NssmService([string]$n){
  $r = Invoke-ServiceRemove $n $script:nssm
  if(-not $r.ok){
    if($r.exitCode -ne 0){ throw "NSSM remove 失败($($r.exitCode)): $($r.detail)" }
    throw "NSSM remove 未生效：$($r.why)"
  }
}
