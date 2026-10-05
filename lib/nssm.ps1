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
  # install 成功后服务已进服务数据库；任意 set 失败都会留下配置不全的半注册残骸
  # （无日志重定向/轮转/AppExit）。失败时尽力 remove 回滚，再抛原始错误。
  try {
    foreach($s in Get-NssmSetSpec $n $dir $par $envPairs){ nssm-set $n $s.k $s.v }
  } catch {
    try { & $script:nssm remove $n confirm 2>&1 | Out-Null } catch {}
    throw
  }
}

function Remove-NssmService([string]$n){
  sc.exe stop $n 2>&1 | Out-Null
  # stop 失败不阻断（服务可能已停），等 Stopped 再删，避免删一个还在跑的服务
  [void](Wait-Stopped $n)
  $o=& $script:nssm remove $n confirm 2>&1
  if($LASTEXITCODE -ne 0){ throw "NSSM remove 失败($LASTEXITCODE): $($o -join ' ')" }
}
