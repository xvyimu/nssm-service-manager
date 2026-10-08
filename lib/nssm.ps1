# lib/nssm.ps1 — NSSM 操作包装：set / install / remove
#
# 从 lib/util.ps1（nssm-set）与 lib/add-svc.ps1（Install/Remove）合并抽出。
# 不含 UI、不含输入校验——纯 NSSM 命令包装，失败抛错。
#
# 【作用域约定】读调用方的 $script:nssm（NSSM exe 路径）与 $logDir（日志目录，
# Install-NssmService 经 Get-NssmSetSpec 拼日志路径）。两者由 service-manager-gui.ps1
# 或测试夹具在 dot-source 之后赋值。
#
# 自加载依赖：Get-NssmSetSpec（svc-input.ps1）、Wait-Stopped（svc-common.ps1）——
# 本文件单独点源也能工作，不必依赖调用方先加载。两个依赖文件均无反向依赖，无循环。
. (Join-Path $PSScriptRoot 'svc-input.ps1')
. (Join-Path $PSScriptRoot 'svc-common.ps1')

# NSSM set 包装：失败抛错
function nssm-set([string]$n,[string]$k,[Parameter(ValueFromRemainingArguments=$true)][object[]]$v){
  $o=& $script:nssm set $n $k @v 2>&1
  if($LASTEXITCODE -ne 0){ throw "NSSM set $k 失败($LASTEXITCODE): $($o -join ' ')" }
}

# GUI/CLI 共用 NSSM 注册与配置；输入校验、错误显示、保存和启动仍由调用方处理。
function Install-NssmService([string]$n,[string]$exe,[string]$dir,[string]$par,$envPairs){
  $nssmOut=& $script:nssm install $n $exe 2>&1
  if($LASTEXITCODE -ne 0){ throw "NSSM install 失败($LASTEXITCODE): $($nssmOut -join ' ')" }
  # install 的退出码同样不可信（实测：提权不足时打印 "Administrator access is needed"
  # 却返回 0）。若真没装上，后续 set 会全挂，报出的却是 set 的错——误导排查方向。
  # 以「服务是否真出现」复核一次，失败即抛，错误信息直指根因。
  if(-not (Test-ServicePresent $n)){
    $why = if(($nssmOut -join ' ') -match 'Administrator access'){ '需要管理员权限' } else { '服务未创建' }
    throw "NSSM install 未生效：$why"
  }
  # install 成功后服务已进服务数据库；任意 set 失败都会留下配置不全的半注册残骸
  # （无日志重定向/轮转/AppExit）。失败时尽力 remove 回滚，再抛原始错误。
  # 日志轮转阈值与停止收尾毫秒从 config 取（默认值与 svc-input.ps1 的形参默认值一致）。
  # config 可能未加载（单独点源本模块时）——用 $null 判断回落，不靠 [int]$null=0。
  $rotateBytes = if ($script:config -and $script:config.AppRotateBytes) { [int]$script:config.AppRotateBytes } else { 5242880 }
  $stopMethod  = if ($script:config -and $script:config.AppStopMethodConsole) { [int]$script:config.AppStopMethodConsole } else { 5000 }
  try {
    foreach($s in Get-NssmSetSpec $n $dir $par $envPairs $rotateBytes $stopMethod){ nssm-set $n $s.k $s.v }
  } catch {
    # 回滚失败不该盖掉原始错误（$s 未配全才是根因）；但也不能静默——回滚没成功意味着
    # 残骸服务还留在服务数据库里，用户需要知道。
    try {
      & $script:nssm remove $n confirm 2>&1 | Out-Null
      if(-not (Test-ServiceGone $n)){
        Write-Warning "回滚未生效：$n 可能仍残留在服务数据库，请手动 nssm remove $n confirm"
      }
    } catch { Write-Warning "回滚失败：$n 可能仍残留在服务数据库（$($_.Exception.Message)）" }
    throw
  }
}

# 删除 NSSM 服务（stop → 等 Stopped → nssm remove confirm → 实证复核）。
# 序列本体在 svc-common.ps1 的 Invoke-ServiceRemove——那里与 poll.ps1 的 runspace 共享
# 同一份文本，避免「两处各写一份、只改一边」的漂移。本函数只负责把失败**抛成异常**，
# 供 UI/CLI 侧调用方（它们用 try/catch）。
#
# 【当前无生产调用方，保留是有意的】GUI 删除走 Show-Remove → 命令队列 → runspace 的
# Invoke-ServiceRemove（异步，不阻塞 UI）；CLI 只有 -Add，没有 -Remove。本函数是
# Install-NssmService 的对称出口，也是「同步删除、失败抛异常」这条契约的唯一实现——
# CLI 将来加 -Remove 时要用它。留着的另一个作用：它是 Invoke-ServiceRemove 的直接
# 单测入口（tests/test-add-svc.ps1）。**下次死代码扫描请勿再删**，除非同时撤掉
# README / docs/PROJECT.md 的模块 API 登记。
function Remove-NssmService([string]$n){
  $r = Invoke-ServiceRemove $n $script:nssm
  if(-not $r.ok){
    if($r.exitCode -ne 0){ throw "NSSM remove 失败($($r.exitCode)): $($r.detail)" }
    throw "NSSM remove 未生效：$($r.why)"
  }
}
