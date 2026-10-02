# lib/theme.ps1 — 系统字体 · 桌面工具配色 · Mica P/Invoke
# 图标是静态文件 assets/icon.ico（已进仓），不再运行时生成 → 不加载 System.Drawing

# 使用 Windows 自带字体，不枚举或依赖额外安装的字体。
$script:cjkFont = 'Microsoft YaHei UI'
$script:fontMono = 'Consolas'

# 当前界面使用的主题色；动态状态色由 card.ps1 统一管理。
# 改色只动这一份——card.ps1 / xaml.ps1 / theme.ps1 按钮模板都从 $script:T 取，不内联硬编码（发现 6）。
$script:T = @{
  Card    = '#FCFDFE'
  CardBrd = '#D7E0EA'
  Fg      = '#1C2939'
  Dim     = '#5C6D7E'
  RootBg  = '#E6EEF2F6'   # 主窗口根 Border 背景（Mica 之上的底色）
  PortBg  = '#EDF2F7'     # 卡片端口徽章背景
  Accent  = '#185A9D'     # 打开面板 / 添加服务按钮前景
  # 按钮模板色（自包含一套，不与卡片色混用）
  BtnBg     = '#FFFFFF'
  BtnFg     = '#263B50'
  BtnBrd    = '#D7E0EA'
  BtnHover  = '#EAF2FC'
  BtnPress  = '#D7E8FC'
  BtnFocus  = '#2469AD'
}

# 原生 WPF 按钮模板：统一触控区域，保留键盘焦点、禁用与悬停反馈。
# 色值从 $script:T 取（按钮模板色），不内联硬编码——改色只动 theme.ps1 一份。
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

# ---- Mica 玻璃背景：DwmSetWindowAttribute(DWMWA_SYSTEMBACKDROP_TYPE) ----
# 官方 API（Win11 22000+），比 SetWindowCompositionAttribute 稳
# type: 2=Mica(主窗口) 3=Acrylic(瞬时) 4=TabbedMica
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
