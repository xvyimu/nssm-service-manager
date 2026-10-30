# lib/add-svc.ps1 — CLI 添加服务（-Add Name,Port,Exe[,Url,Dir,Args,Env]）
# 纯函数族在 svc-input.ps1、NSSM 在 nssm.ps1、对话框在 dialogs.ps1。实现细节：docs/IMPLEMENTATION-NOTES.md
if (-not $script:config) { . (Join-Path $PSScriptRoot 'config.ps1') }

# CLI 模式：解析逗号分隔参数，注册并启动服务，不弹 GUI。§Add-SvcFromCli
function Add-SvcFromCli([string]$spec){
  # 只切前 6 段：第 7 段 Env 里的逗号必须原样保留。
  $parts = $spec -split ',', 7
  if ($parts.Count -lt 3) { Write-Host "用法: -Add Name,Port,Exe[,Url,Dir,Args,Env]"; exit 1 }
  $n=$parts[0].Trim(); $exe=$parts[2].Trim()
  # 先 TryParse：裸 [int] 强转会让端口写成 `8080ms` 时抛栈，用户看不到用法。
  $p=0
  if(-not [int]::TryParse($parts[1].Trim(),[ref]$p)){ Write-Host "端口必须是 1-65535 的整数：$($parts[1])"; Write-Host "用法: -Add Name,Port,Exe[,Url,Dir,Args,Env]"; exit 1 }
  $url=if($parts.Count -gt 3){$parts[3].Trim()}else{"http://127.0.0.1:$p"}
  $dir=if($parts.Count -gt 4){$parts[4].Trim()}else{''}
  $par=if($parts.Count -gt 5){$parts[5].Trim()}else{''}
  # 第 7 段往后全属 Env；分号优先，逗号也能分（ConvertTo-EnvPairs 只在 KEY= 处断开）。
  $envRaw=if($parts.Count -gt 6){$parts[6].Trim()}else{''}
  # 校验顺序：名称 → 可执行文件 → 端口 → 重名（与 GUI 同，抽进 Test-SvcInput）
  $bad = Test-SvcInput $n $p $exe $script:svc
  if($bad){ Write-Host $bad.msg; exit 1 }
  # 先按分号切再按逗号切：NO_PROXY 的多地址保留为一条，A=1,B=2 拆成两条。
  $envPairs = @(ConvertTo-EnvPairs $envRaw ';' | ForEach-Object { ConvertTo-EnvPairs $_ ',' })
  try {
    Install-NssmService $n $exe $dir $par $envPairs
  } catch { Write-Host "注册失败: $($_.Exception.Message)"; exit 1 }
  # 敏感键名只提示不阻断：明文会进注册表（BUILTIN\Users 可读），建议改用 *_FILE。
  $sensitive = Find-SensitiveEnvKeys $envPairs
  if ($sensitive.Count) {
    Write-Host "提示: 以下环境变量将明文写入注册表（BUILTIN\Users 可读）：$($sensitive -join ', ')"
    Write-Host "      推荐改用 *_FILE 路径让服务本体从密钥文件读，文件权限收口到 Administrators+SYSTEM。"
  }
  $saveErr = Add-SvcEntry $n $p $url
  if ($saveErr) {
    # 服务已注册但未落盘：不回滚（会丢可用服务），提示手动迁移。
    Write-Host "警告: 服务已注册但配置保存失败：$saveErr"
    Write-Host "$n 已在 NSSM 注册，请手动将其加入 services.json 或用 -Add 重新注册后删除旧服务。"
    exit 1
  }
  $startCode = Invoke-ScQuiet @('start', $n)
  if ($startCode -ne 0) {
    # 启动失败不回滚也不 exit 1，但绝不谎报成功；原因经 Convert-ScExitCode 映射。
    $reason = Convert-ScExitCode $startCode
    Write-Host "$n 已添加，但启动失败（$startCode $reason）——服务已注册，可在 GUI 右键「启动」查看原因。"
  } else {
    Write-Host "$n 已添加并启动 (port=$p url=$url)"
  }
}

. (Join-Path $PSScriptRoot 'svc-common.ps1')
# 自加载依赖：svc-input.ps1 → nssm.ps1 → svc-common.ps1（CLI 模式只点源 util + add-svc）。§文件头 · 自加载
. (Join-Path $PSScriptRoot 'svc-input.ps1')
. (Join-Path $PSScriptRoot 'nssm.ps1')
