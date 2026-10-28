# lib/add-svc.ps1 — CLI 添加服务（-Add Name,Port,Exe[,Url,Dir,Args,Env]）
#
# 纯函数族在 svc-input.ps1、NSSM 注册/删除在 nssm.ps1、对话框在 dialogs.ps1；
# 本文件只剩 CLI 入口与自加载钩子（CLI 模式不加载 config.ps1，Wait-Stopped 需要默认值）。
if (-not $script:config) { . (Join-Path $PSScriptRoot 'config.ps1') }

# CLI 模式：解析逗号分隔参数，注册 NSSM 服务并启动，不弹 GUI
# 用法：-Add Name,Port,Exe[,Url,Dir,Args,Env]
#   Env 多对用分号分隔：KEY=VAL;KEY2=VAL2；逗号分隔也认（只在 KEY= 处断开，值里的逗号不算）
function Add-SvcFromCli([string]$spec){
  # 只切前 6 段：第 7 段是 Env，里面的逗号必须原样留着（NO_PROXY=127.0.0.1,localhost）。
  # 原实现先全切再 join 回，看似无损，实际 Env 已按逗号拆散过一次。
  $parts = $spec -split ',', 7
  if ($parts.Count -lt 3) { Write-Host "用法: -Add Name,Port,Exe[,Url,Dir,Args,Env]"; exit 1 }
  $n=$parts[0].Trim(); $p=[int]$parts[1].Trim(); $exe=$parts[2].Trim()
  $url=if($parts.Count -gt 3){$parts[3].Trim()}else{"http://127.0.0.1:$p"}
  $dir=if($parts.Count -gt 4){$parts[4].Trim()}else{''}
  $par=if($parts.Count -gt 5){$parts[5].Trim()}else{''}
  # Env：第 7 段往后全部属于 Env（Args 可能含逗号的情况不处理——Args 不应含逗号）
  # 多对 env 优先用分号分隔；逗号分隔也认，因为 ConvertTo-EnvPairs 只在 KEY= 处真断开，
  # 值里的逗号不会被当成下一对。
  $envRaw=if($parts.Count -gt 6){$parts[6].Trim()}else{''}
  # 校验顺序：名称 → 可执行文件 → 端口 → 重名（与 GUI 同，抽进 Test-SvcInput）
  $bad = Test-SvcInput $n $p $exe $script:svc
  if($bad){ Write-Host $bad.msg; exit 1 }
  # 先按分号切，再按逗号切一次——逗号这一轮用的是「只在 KEY= 处断开」的规则，
  # 故 NO_PROXY=127.0.0.1,localhost 原样保留为一条，而 A=1,B=2 会拆成两条。
  $envPairs = @(ConvertTo-EnvPairs $envRaw ';' | ForEach-Object { ConvertTo-EnvPairs $_ ',' })
  try {
    Install-NssmService $n $exe $dir $par $envPairs
  } catch { Write-Host "注册失败: $($_.Exception.Message)"; exit 1 }
  # 敏感键名提示：明文密钥会进注册表 AppEnvironmentExtra（BUILTIN\Users 可读）。
  # CLI 不阻断，只把命中键名列出来提示用户改用 *_FILE。
  $sensitive = Find-SensitiveEnvKeys $envPairs
  if ($sensitive.Count) {
    Write-Host "提示: 以下环境变量将明文写入注册表（BUILTIN\Users 可读）：$($sensitive -join ', ')"
    Write-Host "      推荐改用 *_FILE 路径让服务本体从密钥文件读，文件权限收口到 Administrators+SYSTEM。"
  }
  $saveErr = Add-SvcEntry $n $p $url
  if ($saveErr) {
    # Save-Svc 失败：NSSM 服务已注册且可用，但 services.json 未落盘。
    # 回滚 NSSM 会丢掉一个实际可用的服务，故不自动 remove——提示用户手动迁移。
    Write-Host "警告: 服务已注册但配置保存失败：$saveErr"
    Write-Host "$n 已在 NSSM 注册，请手动将其加入 services.json 或用 -Add 重新注册后删除旧服务。"
    exit 1
  }
  $startCode = Invoke-ScQuiet @('start', $n)
  if ($startCode -ne 0) {
    # sc.exe start 失败返回非零（实测：5 拒绝访问 / 1051 被禁用 / 1053 进程起不来）。
    # 注册本身是成功的，故不回滚、也不 exit 1——但绝不能报「已启动」：这个 CLI 是给
    # agent 用的，谎报成功会让调用方以为服务在跑。如实说清，并指出去哪儿看真实状态。
    # 文案经 Convert-ScExitCode 映射（与 GUI 同一份，定义在 svc-common.ps1，本文件末尾
    # 点源；函数体内符号是调用时解析，故此处可用）——裸退出码要让 agent 自己查表才知道
    # 能不能重试。
    $reason = Convert-ScExitCode $startCode
    Write-Host "$n 已添加，但启动失败（$startCode $reason）——服务已注册，可在 GUI 右键「启动」查看原因。"
  } else {
    Write-Host "$n 已添加并启动 (port=$p url=$url)"
  }
}

. (Join-Path $PSScriptRoot 'svc-common.ps1')
# 纯函数族与 NSSM 注册/删除已抽去各自文件——本文件自加载，保证 CLI 模式
# （service-manager-gui.ps1 -Add 分支只点源 util.ps1 + add-svc.ps1）拿得到全部依赖：
# svc-input.ps1（Test-SvcInput 等）→ nssm.ps1（Install-NssmService，其内部又用
# svc-input.ps1 的 Get-NssmSetSpec）→ svc-common.ps1（Wait-Stopped）。
. (Join-Path $PSScriptRoot 'svc-input.ps1')
. (Join-Path $PSScriptRoot 'nssm.ps1')
