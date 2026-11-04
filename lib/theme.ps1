# lib/theme.ps1 — 系统字体 · 桌面工具配色 · Mica P/Invoke
# 图标为仓内静态文件，字体用 Windows 自带。实现细节：docs/IMPLEMENTATION-NOTES.md
$script:cjkFont = 'Microsoft YaHei UI'
$script:fontMono = 'Consolas'

# 界面主题色；改色只动这一份（card/xaml/按钮模板都从 $script:T 取，不内联硬编码）。
# 语义色（P5）与三个状态词的对应关系固定：正常=Ok、过渡/待保存=Busy、失败/无响应=Danger、陈旧/未知/已停止=Stale。
# 全部对卡片底色 Card(#FCFDFE) ≥ 4.5:1（WCAG AA 正文）；旧值 Brushes.Orange(#FFA500)≈2.0、
# Green(#008000)≈4.0、Red(#FF0000)≈4.0、Gray(#808080)≈3.9 都不达标，所以不再直接用 Brushes.*。
$script:T = @{
  Card    = '#FCFDFE'
  CardBrd = '#D7E0EA'
  Fg      = '#1C2939'
  Dim     = '#5C6D7E'
  RootBg  = '#E6EEF2F6'   # 主窗口根 Border 背景（Mica 之上的底色）
  PortBg  = '#EDF2F7'     # 卡片端口徽章背景
  Accent  = '#185A9D'     # 打开面板 / 添加服务按钮前景
  Danger  = '#C0392B'     # 破坏性操作（删除服务）+ 失败/无响应：右键菜单项前景 + 删除按钮背景
  Ok      = '#0F7B33'     # 正常 / 运行中（对 #FCFDFE 5.29:1）
  Busy    = '#8A5300'     # 启动中 / 停止中 / 删除中 / 待保存（6.21:1）
  Stale   = '#5C6D7E'     # 状态未知 / 未安装 / 已停止 / 陈旧样本（5.23:1）
  BtnBg     = '#FFFFFF'
  BtnFg     = '#263B50'
  BtnBrd    = '#D7E0EA'
  BtnHover  = '#EAF2FC'
  BtnPress  = '#D7E8FC'
  BtnFocus  = '#2469AD'
}

# 现成画刷：卡片每帧都可能改状态色，用 $script:T.Brush* 直接换引用（已 Freeze，跨线程只读安全），
# 免得每次 [System.Windows.Media.SolidColorBrush]::new 都要分配新对象。
$script:brushConverter = [System.Windows.Media.BrushConverter]::new()
foreach ($pair in @(
    @('BrushFg', 'Fg'), @('BrushDim', 'Dim'), @('BrushAccent', 'Accent'), @('BrushDanger', 'Danger'),
    @('BrushOk', 'Ok'), @('BrushBusy', 'Busy'), @('BrushStale', 'Stale')
  )) {
  $brush = [System.Windows.Media.SolidColorBrush]$script:brushConverter.ConvertFrom($script:T[$pair[1]])
  if (-not $brush.IsFrozen) { $brush.Freeze() }
  $script:T[$pair[0]] = $brush
}

# 原生 WPF 按钮模板：统一触控区域，保留焦点/禁用/悬停反馈；色值从 $script:T 取。
$btnT = $script:T
$script:buttonStyle = [System.Windows.Markup.XamlReader]::Parse(@"
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
       xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="{x:Type Button}">
  <Setter Property="Background" Value="$($btnT.BtnBg)"/>
  <Setter Property="Foreground" Value="$($btnT.BtnFg)"/>
  <Setter Property="BorderBrush" Value="$($btnT.BtnBrd)"/>
  <Setter Property="BorderThickness" Value="1"/>
  <Setter Property="Padding" Value="14,7"/>
  <Setter Property="MinHeight" Value="34"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="{x:Type Button}">
        <Border x:Name="Chrome" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Chrome" Property="Background" Value="$($btnT.BtnHover)"/></Trigger>
          <Trigger Property="IsPressed" Value="True"><Setter TargetName="Chrome" Property="Background" Value="$($btnT.BtnPress)"/></Trigger>
          <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Chrome" Property="BorderBrush" Value="$($btnT.BtnFocus)"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
"@)

# ---- Mica 玻璃背景（Win11 22000+）：type 2=Mica 3=Acrylic 4=TabbedMica。§Set-Backdrop
Add-Type -Namespace Win32 -Name Dwm -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int val, int sz);
'@
$script:DWMWA_SYSTEMBACKDROP_TYPE = 38

function Set-Backdrop([System.IntPtr]$hwnd, [int]$type = 2) {
  [Win32.Dwm]::DwmSetWindowAttribute($hwnd, $script:DWMWA_SYSTEMBACKDROP_TYPE, [ref]$type, 4) | Out-Null
}

# 图标路径（静态文件，主入口直接设到窗口 Icon，不在本模块加载 System.Drawing 生成）
$script:iconPath = "$PSScriptRoot\..\assets\icon.ico"
