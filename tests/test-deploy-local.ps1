#requires -Version 7.0
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-helpers.ps1')

# 只加载函数，不执行提权、真实 ACL 或部署。文件操作仍用真实临时目录。
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/deploy-local.ps1'), [ref]$tokens, [ref]$errors)
foreach ($name in 'Restore-Backup','Copy-LocalConfig','Invoke-DeployFiles','Get-NssmSource') {
  $fn = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }.GetNewClosure(), $true)
  if ($fn) { . ([scriptblock]::Create($fn.Extent.Text)) }
}
$fixture = New-TestTempDir 'sm-deploy'
try {
  $source = Join-Path $fixture 'source'; $target = Join-Path $fixture 'target'; $backup = Join-Path $fixture 'backup'
  New-Item -ItemType Directory -Path $source,$target,$backup | Out-Null
  foreach ($path in @((Join-Path $target 'old.ps1'),(Join-Path $backup 'old.ps1'))) { [IO.File]::WriteAllText($path,'old') }
  [IO.File]::WriteAllText((Join-Path $target 'new.ps1'),'new')
  [IO.File]::WriteAllText((Join-Path $target 'old.ps1'),'changed')
  $null = Restore-Backup @('old.ps1','new.ps1') $backup $target
  Assert ((Get-Content -LiteralPath (Join-Path $target 'old.ps1') -Raw) -eq 'old') '旧文件应从备份恢复'
  Assert (-not (Test-Path -LiteralPath (Join-Path $target 'new.ps1'))) '失败时本轮新增文件必须移除'
  Write-Output 'PASS: 恢复旧文件并撤销本轮新增文件'

  foreach ($f in 'old.ps1','new.ps1') { [IO.File]::WriteAllText((Join-Path $source $f),'new') }
  [IO.File]::WriteAllText((Join-Path $target 'services.json'),'local-services')
  [IO.File]::WriteAllText((Join-Path $target 'config.json'),'local-config')
  New-Item -ItemType Directory -Path (Join-Path $target 'scripts'),(Join-Path $backup 'scripts') | Out-Null
  foreach ($path in @((Join-Path $target 'scripts\deploy.cmd'),(Join-Path $backup 'scripts\deploy.cmd'))) { [IO.File]::WriteAllText($path,'legacy-launcher') }
  $expectedHash = (Get-FileHash -LiteralPath (Join-Path $target 'old.ps1')).Hash

  function Get-Command { param([string]$Name,[string]$ErrorAction) $null }
  function Test-Path { param([string]$LiteralPath) $false }
  $failure = $null
  try { Get-NssmSource 'missing-nssm.exe' } catch { $failure = $_ }
  Remove-Item Function:Get-Command,Function:Test-Path
  Assert ($failure.Exception.Message -match '未找到 nssm.exe') '依赖不存在时应在预检报告明确原因'
  Assert ((Get-FileHash -LiteralPath (Join-Path $target 'old.ps1')).Hash -eq $expectedHash) '依赖预检不得覆盖现存文件'
  $dependencyCheck = $ast.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Get-NssmSource' }, $true)
  $fileDeployment = $ast.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-DeployFiles' }, $true)
  Assert ($dependencyCheck.Extent.StartOffset -lt $fileDeployment.Extent.StartOffset) '真实部署入口必须先验证NSSM再开始文件覆盖'
  Write-Output 'PASS: NSSM依赖缺失在文件覆盖前终止'

  # 当前目标先被截断才抛错：该条目也必须在恢复范围内。
  function Copy-Item {
    param([string]$LiteralPath,[string]$Destination,[switch]$Force)
    if ($LiteralPath -eq (Join-Path $source 'old.ps1')) {
      [IO.File]::WriteAllText($Destination,'partial')
      throw 'injected partial copy'
    }
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
  }
  $failure = $null
  try { Invoke-DeployFiles $source $target $backup @('new.ps1','old.ps1') {} } catch { $failure = $_ }
  Remove-Item Function:Copy-Item
  Assert ($failure.Exception.Message -match 'injected partial copy') '应保留复制失败原因'
  Assert ((Get-FileHash -LiteralPath (Join-Path $target 'old.ps1')).Hash -eq $expectedHash) '部分复制失败的当前文件应恢复旧哈希'
  Assert (-not (Test-Path -LiteralPath (Join-Path $target 'new.ps1'))) '之前新增的文件不得残留'
  Write-Output 'PASS: 部分复制失败时恢复当前文件哈希及原文件集'

  $failure = $null
  try { Invoke-DeployFiles $source $target $backup @('new.ps1','old.ps1') { throw 'injected completion failure' } } catch { $failure = $_ }
  Assert ($failure.Exception.Message -match 'injected completion failure') '后续完成阶段应进入恢复路径'
  Assert ((Get-FileHash -LiteralPath (Join-Path $target 'old.ps1')).Hash -eq $expectedHash) '完成阶段失败应恢复旧哈希'
  Assert (-not (Test-Path -LiteralPath (Join-Path $target 'new.ps1'))) '完成阶段失败应移除新增文件'
  Assert ((Get-Content -LiteralPath (Join-Path $target 'services.json') -Raw) -eq 'local-services') '实配服务清单不得改变'
  Assert ((Get-Content -LiteralPath (Join-Path $target 'config.json') -Raw) -eq 'local-config') '实配配置不得改变'
  Assert ((Get-Content -LiteralPath (Join-Path $target 'scripts\deploy.cmd') -Raw) -eq 'legacy-launcher') '后续自检失败应恢复已退役的旧入口'
  Write-Output 'PASS: 后续自检失败仍恢复程序文件且保留实配'

  Invoke-DeployFiles $source $target $backup @('new.ps1','old.ps1') {}
  Assert (-not (Test-Path -LiteralPath (Join-Path $target 'scripts\deploy.cmd'))) '部署成功后应精确退役旧cmd入口'
  Assert ((Get-Content -LiteralPath (Join-Path $target 'old.ps1') -Raw) -eq 'new') '部署成功应保留新程序内容'
  Write-Output 'PASS: 部署成功保留新版且退役旧cmd入口，失败时可恢复旧入口'

  # 首次部署迁移本机配置：复制中途失败不得留下半截清单——留下后下次部署因目标存在而跳过迁移，
  # GUI 会按坏清单启动。
  $migrateSource = Join-Path $fixture 'migrate-source'; $migrateTarget = Join-Path $fixture 'migrate-target'
  New-Item -ItemType Directory -Path $migrateSource,$migrateTarget | Out-Null
  [IO.File]::WriteAllText((Join-Path $migrateSource 'program.ps1'),'new')
  foreach ($f in 'services.json','config.json') { [IO.File]::WriteAllText((Join-Path $migrateSource $f),'src') }
  function Copy-Item {
    param([string]$LiteralPath,[string]$Destination,[switch]$Force)
    if ($LiteralPath -eq (Join-Path $migrateSource 'services.json')) {
      [IO.File]::WriteAllText($Destination,'truncated')
      throw 'injected migration failure'
    }
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
  }
  $failure = $null
  try { Copy-LocalConfig $migrateSource $migrateTarget } catch { $failure = $_ }
  Remove-Item Function:Copy-Item
  Assert ($failure.Exception.Message -match 'injected migration failure') '迁移失败应保留原始错误'
  Assert (-not (Test-Path -LiteralPath (Join-Path $migrateTarget 'services.json'))) '半截清单不得留在目标目录'
  Assert (-not (Test-Path -LiteralPath (Join-Path $migrateTarget 'config.json'))) '迁移首个文件失败后不得继续'
  Write-Output 'PASS: 本机配置迁移失败时不留下半截清单'
} finally {
  if (Test-Path -LiteralPath $fixture) {
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not [IO.Path]::GetFullPath($fixture).StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw '测试清理路径超出临时目录' }
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($fixture,'OnlyErrorDialogs','SendToRecycleBin')
  }
}
