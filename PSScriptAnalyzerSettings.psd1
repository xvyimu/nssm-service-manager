# PSScriptAnalyzerSettings.psd1 — 静态分析规则集（CI 与本地同一份）
#
# 用法：pwsh -NoProfile -File tests/analyze.ps1
#      或 pwsh -c "Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1"
#
# 原则：先跑通、再收紧。这里只关掉**本仓库有意为之**的规则并写明理由；
# 其余 Error/Warning 一律必须为 0，新增告警由 CI 拦下。
@{
  Severity = @('Error', 'Warning')
  ExcludeRules = @(
    # 仓库统一 UTF-8 无 BOM（全局编码规范；带 BOM 会让 CI diff 与拼接 poll 脚本块多出字节）
    'PSUseBOMForUnicodeEncodedFile',
    # 容错清理有意留空 catch：清只读属性、写 crash log 失败不该改变主流程
    'PSAvoidUsingEmptyCatchBlock',
    # 内部 helper 不实现 -WhatIf/-Confirm（Stop-Background 只给测试与退出用）
    'PSUseShouldProcessForStateChangingFunctions',
    # 领域命名按服务/页面语义：Load-Svc / Render-Page / Drain-Queue / Open-PanelUrl
    'PSUseSingularNouns',
    'PSUseApprovedVerbs',
    # WPF 事件体的 param($sender,$eventArgs) 是框架回调签名，不是给自动变量赋值
    'PSAvoidAssignmentToAutomaticVariable',
    # 事件回调签名固定，未用到的 $s/$e 不能删（删了 RaiseEvent 绑定就断）
    'PSReviewUnusedParameter',
    # 测试故意替身 Start-Process / Get-Service / sc.exe / Save-Svc
    'PSAvoidOverwritingBuiltInCmdlets',
    # CLI 分支（-Add）与安装脚本把进度打到控制台：Write-Host 走信息流，不会污染管道数据；
    # 改成 Write-Output 会让调用方拿到进度字符串。
    'PSAvoidUsingWriteHost'
  )
}
