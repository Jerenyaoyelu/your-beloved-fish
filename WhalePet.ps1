# ============================================================================
#  小鲸鱼桌宠 (Whale Pet) v0.2
#  · 始终置顶、透明无边框、可拖拽、点击冒泡、双击聊天
#  · 本地记忆：事实 / 待办 / 提醒 / 摘要 / 逐轮对话（关机不丢）
#  · 工作助手：工具调用（记待办、设提醒、长期记忆、查记忆、查时间）
#  · 自我进化：自动抽取记忆 + 每日整理，更新 persona.md
#  启动：双击 启动小鲸鱼.vbs
# ============================================================================
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Security

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:WhalePng = Join-Path $script:AppDir 'assets\whale.png'

function Initialize-DataDir {
  $candidates = @(
    (Join-Path $script:AppDir 'data'),
    (Join-Path $env:APPDATA 'DeepSeekWhalePet')
  )
  foreach ($d in $candidates) {
    try {
      if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
      $probe = Join-Path $d '.write-test'
      Set-Content -LiteralPath $probe -Value 'x' -ErrorAction Stop
      Remove-Item $probe -Force -ErrorAction SilentlyContinue
      return $d
    } catch { }
  }
  return (Join-Path $script:AppDir 'data')
}

$script:DataDir = Initialize-DataDir
$script:ConfigPath = Join-Path $script:DataDir 'config.json'
$script:LogPath = Join-Path $script:DataDir 'whale-pet.log'

function Write-Log([string]$Message) {
  try {
    if ((Test-Path $script:LogPath) -and ((Get-Item $script:LogPath).Length -gt 1048576)) {
      Remove-Item $script:LogPath -Force -ErrorAction SilentlyContinue
    }
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
  } catch { }
}

Write-Log ("=== 启动 v0.2，数据目录: " + $script:DataDir + " ===")

trap {
  $logFile = if ($script:DataDir) { Join-Path $script:DataDir 'fatal.log' } else { Join-Path $env:TEMP 'whale-pet-fatal.log' }
  try { [System.IO.File]::AppendAllText($logFile, ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "  FATAL: " + $_.Exception.ToString() + "`r`n")) } catch { }
  try { [System.Windows.MessageBox]::Show(($_.Exception.Message + "`n`n详细信息见 `n" + $logFile), '小鲸鱼启动失败') | Out-Null } catch { }
  exit 1
}

# ---------------------------------------------------------------- 模块
Import-Module (Join-Path $script:AppDir 'lib\Store.psm1') -Force
Import-Module (Join-Path $script:AppDir 'lib\Brain.psm1') -Force
Import-Module (Join-Path $script:AppDir 'lib\Skins.psm1') -Force

$script:FreshMemory = -not (Test-Path (Join-Path $script:DataDir 'memory.json'))
Initialize-Store -DataDir $script:DataDir
Initialize-Skins -DataDir $script:DataDir -DefaultImage $script:WhalePng

# ---------------------------------------------------------------- 单实例
$script:Mutex = New-Object System.Threading.Mutex($false, 'Local\DeepSeekWhalePet')
try {
  if (-not $script:Mutex.WaitOne(5000)) {
    Write-Log '已有实例在运行，退出。'
    exit 0
  }
} catch { }

# ---------------------------------------------------------------- 配置
function New-DefaultConfig {
  return [pscustomobject]@{
    apiKeyProtected = ''
    model           = 'deepseek-chat'
    posX            = $null
    posY            = $null
    topmost         = $true
    autoStart       = $true
    lowBalanceThreshold = 5
    lastBalanceLow  = $false
    todayDate       = (Get-Date).ToString('yyyy-MM-dd')
    todayTokens     = 0
  }
}

function Load-Config {
  $cfg = New-DefaultConfig
  if (Test-Path $script:ConfigPath) {
    try {
      $saved = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($p in $saved.PSObject.Properties) {
        if ($null -ne $cfg.PSObject.Properties[$p.Name]) { $cfg.($p.Name) = $p.Value }
      }
    } catch { Write-Log ("配置读取失败: " + $_.Exception.Message) }
  }
  return $cfg
}

function Save-Config {
  try {
    $script:Config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
  } catch { Write-Log ("配置保存失败: " + $_.Exception.Message) }
}

function Protect-Text([string]$Text) {
  if ([string]::IsNullOrEmpty($Text)) { return '' }
  $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
  $enc = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
  return [Convert]::ToBase64String($enc)
}

function Unprotect-Text([string]$B64) {
  if ([string]::IsNullOrEmpty($B64)) { return '' }
  $enc = [Convert]::FromBase64String($B64)
  $bytes = [Security.Cryptography.ProtectedData]::Unprotect($enc, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
  return [Text.Encoding]::UTF8.GetString($bytes)
}

function Get-ApiKey {
  if (-not [string]::IsNullOrWhiteSpace($env:DEEPSEEK_API_KEY)) { return $env:DEEPSEEK_API_KEY.Trim() }
  if ([string]::IsNullOrWhiteSpace($script:Config.apiKeyProtected)) { return '' }
  try { return (Unprotect-Text $script:Config.apiKeyProtected).Trim() }
  catch { Write-Log 'API Key 解密失败'; return '' }
}

function Get-Brush([string]$Hex) {
  return (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Hex)
}

# ---------------------------------------------------------------- Win32 辅助
if (-not ('WhalePetWin32' -as [type])) {
  Add-Type -Namespace '' -Name 'WhalePetWin32' -MemberDefinition @'
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
'@
}

function Set-ToolWindowStyle($Window) {
  try {
    $helper = New-Object System.Windows.Interop.WindowInteropHelper($Window)
    $hwnd = $helper.Handle
    $ex = [WhalePetWin32]::GetWindowLong($hwnd, -20)
    [WhalePetWin32]::SetWindowLong($hwnd, -20, ($ex -bor 0x00000080)) | Out-Null
  } catch { Write-Log ("设置工具窗口样式失败: " + $_.Exception.Message) }
}

function Get-WorkArea { return [System.Windows.SystemParameters]::WorkArea }

function Clamp-Window($Window) {
  $wa = Get-WorkArea
  if ($Window.Left -lt $wa.Left) { $Window.Left = $wa.Left }
  if ($Window.Top -lt $wa.Top) { $Window.Top = $wa.Top }
  $maxL = $wa.Right - $Window.Width
  $maxT = $wa.Bottom - $Window.Height
  if ($Window.Left -gt $maxL) { $Window.Left = $maxL }
  if ($Window.Top -gt $maxT) { $Window.Top = $maxT }
}

# ---------------------------------------------------------------- 开机自启
function Get-AutostartLink {
  return (Join-Path ([Environment]::GetFolderPath('Startup')) '小鲸鱼桌宠.lnk')
}

function Set-Autostart([bool]$On) {
  $lnk = Get-AutostartLink
  try {
    if ($On) {
      $ws = New-Object -ComObject WScript.Shell
      $sc = $ws.CreateShortcut($lnk)
      $sc.TargetPath = (Join-Path $env:WINDIR 'System32\wscript.exe')
      $sc.Arguments = '"' + (Join-Path $script:AppDir 'start-whale-pet.vbs') + '"'
      $sc.WorkingDirectory = $script:AppDir
      $sc.Description = '小鲸鱼桌宠'
      $sc.IconLocation = (Join-Path $script:AppDir 'assets\whale.ico')
      $sc.Save()
    } else {
      if (Test-Path $lnk) { Remove-Item $lnk -Force }
    }
    return $true
  } catch {
    Write-Log ("开机自启设置失败: " + $_.Exception.Message)
    return $false
  }
}

# ============================================================================
#  XAML — 主窗口
# ============================================================================
$xamlMain = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="小鲸鱼" Width="360" Height="430"
        WindowStyle="None" AllowsTransparency="True" Background="{x:Null}"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False"
        ResizeMode="NoResize" WindowStartupLocation="Manual"
        FontFamily="Microsoft YaHei UI">
  <Grid x:Name="RootGrid">
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Grid x:Name="BubbleHost" Grid.Row="0" VerticalAlignment="Bottom" Margin="14,10,14,0"
          Visibility="Collapsed" Opacity="0">
      <StackPanel HorizontalAlignment="Center" VerticalAlignment="Bottom">
        <Border x:Name="BubbleBorder" Background="#FFFDF8" CornerRadius="16"
                BorderBrush="#EADCC8" BorderThickness="1" Padding="14,10"
                MaxWidth="300" HorizontalAlignment="Center">
          <Border.Effect>
            <DropShadowEffect BlurRadius="18" ShadowDepth="3" Opacity="0.20" Color="#3A2A18"/>
          </Border.Effect>
          <StackPanel>
            <TextBlock x:Name="BubbleText" TextWrapping="Wrap" FontSize="13.5"
                       Foreground="#33261A" TextAlignment="Center" LineHeight="19"/>
            <TextBlock x:Name="BubbleSub" TextWrapping="Wrap" FontSize="11"
                       Foreground="#8C7A64" Margin="0,5,0,0" TextAlignment="Center"
                       Visibility="Collapsed" LineHeight="16"/>
          </StackPanel>
        </Border>
        <Path x:Name="BubbleTail" Fill="#FFFDF8" Stroke="#EADCC8" StrokeThickness="1"
              Data="M0,0 L22,0 L11,11 Z" HorizontalAlignment="Center" Margin="0,-1,0,0"/>
      </StackPanel>
    </Grid>

    <Grid x:Name="WhaleHost" Grid.Row="1" Width="250" Height="250"
          HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,4"
          Background="Transparent" Cursor="Hand">
      <Ellipse Width="150" Height="20" VerticalAlignment="Bottom" HorizontalAlignment="Center"
               Margin="0,0,0,4" IsHitTestVisible="False">
        <Ellipse.Fill>
          <RadialGradientBrush>
            <GradientStop Color="#38000000" Offset="0"/>
            <GradientStop Color="#00000000" Offset="1"/>
          </RadialGradientBrush>
        </Ellipse.Fill>
      </Ellipse>
      <Image x:Name="WhaleImage" Width="236" Height="236" Stretch="Uniform"
             VerticalAlignment="Bottom" IsHitTestVisible="False" RenderTransformOrigin="0.5,0.85">
        <Image.RenderTransform>
          <TransformGroup>
            <ScaleTransform x:Name="WhaleScale" ScaleX="1" ScaleY="1"/>
            <RotateTransform x:Name="WhaleRotate" Angle="0"/>
            <TranslateTransform x:Name="WhaleMove" Y="0"/>
          </TransformGroup>
        </Image.RenderTransform>
      </Image>
    </Grid>
  </Grid>
</Window>
'@

# ============================================================================
#  XAML — 聊天窗口
# ============================================================================
$xamlChat = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="和小鲸鱼聊天" Width="430" Height="620"
        WindowStyle="None" AllowsTransparency="True" Background="{x:Null}"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        WindowStartupLocation="Manual" FontFamily="Microsoft YaHei UI">
  <Window.Resources>
    <Style x:Key="PrimaryBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bg" Background="#2F7CF6" CornerRadius="12" Padding="18,8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#1E6BE6"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bg" Property="Background" Value="#B7C9E4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="IconBtn" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Foreground" Value="#8A97A8"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bg" Background="Transparent" CornerRadius="9">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#EEF3FA"/>
                <Setter Property="Foreground" Value="#4A5A6E"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border x:Name="ChatCard" CornerRadius="20" Background="#FFFDFB"
          BorderBrush="#E6EDF7" BorderThickness="1" Margin="10">
    <Border.Effect>
      <DropShadowEffect BlurRadius="30" ShadowDepth="5" Opacity="0.24" Color="#12203A"/>
    </Border.Effect>
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="54"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Grid x:Name="ChatHeader" Grid.Row="0" Background="Transparent">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="18,0,0,0">
          <Ellipse Width="9" Height="9" Fill="#3BC17A" VerticalAlignment="Center"/>
          <TextBlock Text="小鲸鱼" FontSize="15" FontWeight="SemiBold"
                     Foreground="#17202B" Margin="8,0,0,0" VerticalAlignment="Center"/>
          <TextBlock x:Name="ChatBalance" Text="" FontSize="11" Foreground="#7A8798"
                     Margin="10,2,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <Button x:Name="ChatMemory" Content="记忆" Style="{StaticResource IconBtn}"
                Width="46" Height="30" HorizontalAlignment="Right" Margin="0,0,48,0"/>
        <Button x:Name="ChatClose" Content="✕" Style="{StaticResource IconBtn}"
                Width="30" Height="30" HorizontalAlignment="Right" Margin="0,0,12,0"/>
      </Grid>

      <ScrollViewer x:Name="ChatScroll" Grid.Row="1" VerticalScrollBarVisibility="Auto"
                    Padding="12,4,12,6" Background="#FBFDFF">
        <StackPanel x:Name="ChatPanel"/>
      </ScrollViewer>

      <Grid Grid.Row="2" Margin="14,8,14,14">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Border Background="#F3F7FC" CornerRadius="14" BorderBrush="#E3EBF5"
                BorderThickness="1" Padding="10,3,10,3">
          <Grid>
            <TextBlock x:Name="ChatPlaceholder" Text="说点什么…" FontSize="13"
                       Foreground="#9AA7B8" VerticalAlignment="Center" Margin="4,0,0,0"
                       IsHitTestVisible="False"/>
            <TextBox x:Name="ChatInput" Background="Transparent" BorderThickness="0"
                     FontSize="13.5" Foreground="#17202B" VerticalContentAlignment="Center"
                     MinHeight="34" MaxHeight="96" TextWrapping="Wrap" AcceptsReturn="False"/>
          </Grid>
        </Border>
        <Button x:Name="ChatSend" Grid.Column="1" Content="发送"
                Style="{StaticResource PrimaryBtn}" Margin="8,0,0,0" VerticalAlignment="Bottom"/>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

# ============================================================================
#  XAML — 记忆与设定
# ============================================================================
$xamlMemory = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="记忆与设定" Width="640" Height="820"
        WindowStyle="None" AllowsTransparency="True" Background="{x:Null}"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen" FontFamily="Microsoft YaHei UI">
  <Window.Resources>
    <Style x:Key="PrimaryBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bg" Background="#2F7CF6" CornerRadius="10" Padding="16,8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#1E6BE6"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="GhostBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#5B6B7F"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bg" Background="#EEF3FA" CornerRadius="10" Padding="16,8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#E3EBF5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="XBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#A9B4C2"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Width" Value="24"/>
      <Setter Property="Height" Value="24"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="Transparent" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border CornerRadius="20" Background="#FFFDFB" BorderBrush="#E6EDF7"
          BorderThickness="1" Margin="12">
    <Border.Effect>
      <DropShadowEffect BlurRadius="30" ShadowDepth="5" Opacity="0.24" Color="#12203A"/>
    </Border.Effect>
    <Grid Margin="22,18,22,16">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <StackPanel Grid.Row="0" Orientation="Horizontal">
        <TextBlock Text="记忆与设定" FontSize="17" FontWeight="SemiBold" Foreground="#17202B"/>
        <TextBlock x:Name="MemStats" Margin="12,4,0,0" FontSize="11" Foreground="#8A97A8"/>
      </StackPanel>

      <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Margin="0,10,0,0">
        <StackPanel x:Name="MemBody">
          <TextBlock Text="关于你" FontSize="12" FontWeight="SemiBold" Foreground="#7A8798" Margin="0,4,0,4"/>
          <StackPanel x:Name="FactsPanel"/>

          <TextBlock Text="待办" FontSize="12" FontWeight="SemiBold" Foreground="#7A8798" Margin="0,16,0,4"/>
          <StackPanel x:Name="TodoPanel"/>
          <Grid Margin="0,6,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Border Background="#F3F7FC" CornerRadius="10" BorderBrush="#E3EBF5" BorderThickness="1" Padding="8,2">
              <TextBox x:Name="MemTodoInput" Background="Transparent" BorderThickness="0" FontSize="12.5"
                       MinHeight="28" VerticalContentAlignment="Center" Foreground="#17202B"/>
            </Border>
            <Button x:Name="MemTodoAdd" Grid.Column="1" Content="添加" Style="{StaticResource GhostBtn}"
                    Margin="8,0,0,0" Padding="14,6"/>
          </Grid>

          <TextBlock Text="最近摘要" FontSize="12" FontWeight="SemiBold" Foreground="#7A8798" Margin="0,18,0,4"/>
          <TextBlock x:Name="SummariesText" TextWrapping="Wrap" FontSize="12" Foreground="#5B6B7F" LineHeight="18"/>

          <TextBlock Text="人设（可编辑，小鲸鱼会自己补充“我学到的”）" FontSize="12" FontWeight="SemiBold"
                     Foreground="#7A8798" Margin="0,18,0,4"/>
          <TextBox x:Name="PersonaBox" Height="200" AcceptsReturn="True" TextWrapping="Wrap"
                   VerticalScrollBarVisibility="Auto" FontSize="12" Foreground="#1B2430"
                   Background="#F8FAFD" BorderBrush="#E3EBF5" BorderThickness="1" Padding="8"/>
        </StackPanel>
      </ScrollViewer>

      <Grid Grid.Row="2" Margin="0,12,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="MemStatus" FontSize="11" Foreground="#8A97A8" VerticalAlignment="Center"/>
        <StackPanel Grid.Column="1" Orientation="Horizontal">
          <Button x:Name="MemReflect" Content="整理记忆" Style="{StaticResource GhostBtn}" Margin="0,0,8,0"/>
          <Button x:Name="MemSavePersona" Content="保存人设" Style="{StaticResource GhostBtn}" Margin="0,0,8,0"/>
          <Button x:Name="MemClose" Content="关闭" Style="{StaticResource PrimaryBtn}"/>
        </StackPanel>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

# ============================================================================
#  XAML — 错过的提醒
# ============================================================================
$xamlMissed = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="错过的提醒" Width="480" Height="430"
        WindowStyle="None" AllowsTransparency="True" Background="{x:Null}"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen" FontFamily="Microsoft YaHei UI">
  <Window.Resources>
    <Style x:Key="PrimaryBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bg" Background="#2F7CF6" CornerRadius="10" Padding="18,8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#1E6BE6"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="GhostBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#5B6B7F"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bg" Background="#EEF3FA" CornerRadius="10" Padding="18,8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#E3EBF5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border CornerRadius="20" Background="#FFFDFB" BorderBrush="#E6EDF7"
          BorderThickness="1" Margin="12">
    <Border.Effect>
      <DropShadowEffect BlurRadius="30" ShadowDepth="5" Opacity="0.24" Color="#12203A"/>
    </Border.Effect>
    <Grid Margin="22,18,22,16">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <StackPanel Grid.Row="0">
        <TextBlock Text="错过的提醒" FontSize="17" FontWeight="SemiBold" Foreground="#17202B"/>
        <TextBlock x:Name="MissedSub" Text="" FontSize="12" Foreground="#7A8798"
                   Margin="0,6,0,0" TextWrapping="Wrap"/>
      </StackPanel>

      <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Margin="0,10,0,0">
        <StackPanel x:Name="MissedList"/>
      </ScrollViewer>

      <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
        <Button x:Name="MissedLater" Content="稍后再说" Style="{StaticResource GhostBtn}" Margin="0,0,8,0"/>
        <Button x:Name="MissedIgnore" Content="忽略" Style="{StaticResource GhostBtn}" Margin="0,0,8,0"/>
        <Button x:Name="MissedReplay" Content="补发" Style="{StaticResource PrimaryBtn}"/>
      </StackPanel>
    </Grid>
  </Border>
</Window>
'@

# ============================================================================
#  XAML — 皮肤
# ============================================================================
$xamlSkin = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="皮肤" Width="620" Height="600"
        WindowStyle="None" AllowsTransparency="True" Background="{x:Null}"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen" FontFamily="Microsoft YaHei UI">
  <Window.Resources>
    <Style x:Key="PrimaryBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bg" Background="#2F7CF6" CornerRadius="10" Padding="18,8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#1E6BE6"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="GhostBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#5B6B7F"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bg" Background="#EEF3FA" CornerRadius="10" Padding="16,8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#E3EBF5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border CornerRadius="20" Background="#FFFDFB" BorderBrush="#E6EDF7"
          BorderThickness="1" Margin="12">
    <Border.Effect>
      <DropShadowEffect BlurRadius="30" ShadowDepth="5" Opacity="0.24" Color="#12203A"/>
    </Border.Effect>
    <Grid Margin="22,18,22,16">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <StackPanel Grid.Row="0">
        <TextBlock Text="皮肤" FontSize="17" FontWeight="SemiBold" Foreground="#17202B"/>
        <TextBlock Text="支持 PNG / GIF / JPG，建议透明背景、正方形；GIF 会动。" FontSize="11.5"
                   Foreground="#8A97A8" Margin="0,6,0,0"/>
      </StackPanel>

      <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Margin="0,10,0,0">
        <StackPanel x:Name="SkinsPanel"/>
      </ScrollViewer>

      <Grid Grid.Row="2" Margin="0,12,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="SkinStatus" FontSize="11" Foreground="#8A97A8" VerticalAlignment="Center"/>
        <StackPanel Grid.Column="1" Orientation="Horizontal">
          <Button x:Name="SkinImport" Content="导入图片" Style="{StaticResource GhostBtn}" Margin="0,0,8,0"/>
          <Button x:Name="SkinDefault" Content="恢复默认" Style="{StaticResource GhostBtn}" Margin="0,0,8,0"/>
          <Button x:Name="SkinClose" Content="关闭" Style="{StaticResource PrimaryBtn}"/>
        </StackPanel>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

# ============================================================================
#  XAML — 设置窗口
# ============================================================================
$xamlSettings = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="小鲸鱼设置" Width="452" Height="392"
        WindowStyle="None" AllowsTransparency="True" Background="{x:Null}"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen" FontFamily="Microsoft YaHei UI">
  <Window.Resources>
    <Style x:Key="PrimaryBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bg" Background="#2F7CF6" CornerRadius="10" Padding="20,8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#1E6BE6"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="GhostBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#5B6B7F"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bg" Background="#EEF3FA" CornerRadius="10" Padding="20,8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#E3EBF5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="LinkBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#2F7CF6"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="6,0,0,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <ContentPresenter VerticalAlignment="Center"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border CornerRadius="18" Background="#FFFDFB" BorderBrush="#E6EDF7"
          BorderThickness="1" Margin="12">
    <Border.Effect>
      <DropShadowEffect BlurRadius="30" ShadowDepth="5" Opacity="0.24" Color="#12203A"/>
    </Border.Effect>
    <Grid Margin="24,20,24,20">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <TextBlock Grid.Row="0" Text="小鲸鱼设置" FontSize="17" FontWeight="SemiBold" Foreground="#17202B"/>

      <TextBlock Grid.Row="1" Text="DeepSeek API Key" FontSize="12" Foreground="#7A8798" Margin="0,16,0,6"/>
      <PasswordBox x:Name="KeyBox" Grid.Row="2" Height="38" FontSize="13" Padding="10,7"
                   Background="#F4F7FC" BorderBrush="#DCE6F2" BorderThickness="1"/>

      <StackPanel Grid.Row="3" Orientation="Horizontal" Margin="0,4,0,0">
        <TextBlock Text="在 platform.deepseek.com → API keys 创建，sk- 开头" FontSize="11"
                   Foreground="#93A0B1" VerticalAlignment="Center"/>
        <Button x:Name="GetKeyBtn" Content="去创建 ↗" Style="{StaticResource LinkBtn}"/>
      </StackPanel>

      <TextBlock Grid.Row="4" Text="模型" FontSize="12" Foreground="#7A8798" Margin="0,14,0,6"/>
      <TextBox x:Name="ModelBox" Grid.Row="5" Height="36" FontSize="13" Padding="10,6"
               Background="#F4F7FC" BorderBrush="#DCE6F2" BorderThickness="1"/>

      <StackPanel Grid.Row="6" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0">
        <Button x:Name="CancelBtn" Content="取消" Style="{StaticResource GhostBtn}" Margin="0,0,10,0"/>
        <Button x:Name="SaveBtn" Content="保存" Style="{StaticResource PrimaryBtn}"/>
      </StackPanel>
    </Grid>
  </Border>
</Window>
'@

function New-WindowFromXaml([string]$Xaml) {
  $xml = New-Object System.Xml.XmlDocument
  $xml.LoadXml($Xaml)
  $reader = New-Object System.Xml.XmlNodeReader($xml)
  return [Windows.Markup.XamlReader]::Load($reader)
}

# ============================================================================
#  状态
# ============================================================================
$script:Config = Load-Config
$script:BalanceText = ''
$script:BalanceOk = $false
$script:BalanceBusy = $false
$script:Pending = @{}
$script:ChatHistory = @()
$script:ChatBusy = $false
$script:ChatPlaceholderBubble = $null
$script:ChatVisible = $false
$script:ChatCtx = $null
$script:Extracting = $false
$script:Reflecting = $false
$script:MemBuilding = $false
$script:ReviewingMissed = $false
$script:MissedIds = @()
$script:MissedPending = @()
$script:BalanceWarned = $false
$script:LastBalanceWarnAt = $null
$script:BalanceWasLow = [bool]$script:Config.lastBalanceLow
$script:GifFrames = @()
$script:GifIndex = 0
$script:GifTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:GifTimer.Interval = [TimeSpan]::FromMilliseconds(100)
$script:IdleLines = @(
  '在呢在呢～', '摸摸头～', '今天也辛苦啦', '要不要聊两句？',
  '点我干嘛呀，嘿嘿', '我一直在这儿哦', '喝口水休息一下嘛', '嘿！'
)

# ============================================================================
#  主窗口
# ============================================================================
$script:MainWindow = New-WindowFromXaml $xamlMain
$script:RootGrid = $script:MainWindow.FindName('RootGrid')
$script:BubbleHost = $script:MainWindow.FindName('BubbleHost')
$script:BubbleText = $script:MainWindow.FindName('BubbleText')
$script:BubbleSub = $script:MainWindow.FindName('BubbleSub')
$script:BubbleBorder = $script:MainWindow.FindName('BubbleBorder')
$script:BubbleTail = $script:MainWindow.FindName('BubbleTail')
$script:WhaleHost = $script:MainWindow.FindName('WhaleHost')
$script:WhaleImage = $script:MainWindow.FindName('WhaleImage')
$script:WhaleScale = $script:MainWindow.FindName('WhaleScale')
$script:WhaleRotate = $script:MainWindow.FindName('WhaleRotate')
$script:WhaleMove = $script:MainWindow.FindName('WhaleMove')

$bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
$bitmap.BeginInit()
$bitmap.CacheOption = 'OnLoad'
$bitmap.UriSource = New-Object System.Uri($script:WhalePng)
$bitmap.EndInit()
$script:WhaleImage.Source = $bitmap

$script:MainWindow.Topmost = [bool]$script:Config.topmost
if ($null -ne $script:Config.posX -and $null -ne $script:Config.posY) {
  $script:MainWindow.Left = [double]$script:Config.posX
  $script:MainWindow.Top = [double]$script:Config.posY
} else {
  $wa = Get-WorkArea
  $script:MainWindow.Left = $wa.Right - $script:MainWindow.Width - 16
  $script:MainWindow.Top = $wa.Bottom - $script:MainWindow.Height - 6
}
Clamp-Window $script:MainWindow

$script:MainWindow.Add_SourceInitialized({ Set-ToolWindowStyle $script:MainWindow })

# ---------------------------------------------------------------- 聊天窗口
$script:ChatWindow = New-WindowFromXaml $xamlChat
$script:ChatCard = $script:ChatWindow.FindName('ChatCard')
$script:ChatHeader = $script:ChatWindow.FindName('ChatHeader')
$script:ChatScroll = $script:ChatWindow.FindName('ChatScroll')
$script:ChatPanel = $script:ChatWindow.FindName('ChatPanel')
$script:ChatInput = $script:ChatWindow.FindName('ChatInput')
$script:ChatPlaceholder = $script:ChatWindow.FindName('ChatPlaceholder')
$script:ChatSend = $script:ChatWindow.FindName('ChatSend')
$script:ChatClose = $script:ChatWindow.FindName('ChatClose')
$script:ChatMemory = $script:ChatWindow.FindName('ChatMemory')
$script:ChatBalance = $script:ChatWindow.FindName('ChatBalance')
$script:ChatWindow.Add_SourceInitialized({ Set-ToolWindowStyle $script:ChatWindow })

# ---------------------------------------------------------------- 错过提醒窗口
$script:MissedWindow = New-WindowFromXaml $xamlMissed
$script:MissedSub = $script:MissedWindow.FindName('MissedSub')
$script:MissedList = $script:MissedWindow.FindName('MissedList')
$script:MissedReplay = $script:MissedWindow.FindName('MissedReplay')
$script:MissedIgnore = $script:MissedWindow.FindName('MissedIgnore')
$script:MissedLater = $script:MissedWindow.FindName('MissedLater')
$script:MissedWindow.Add_SourceInitialized({ Set-ToolWindowStyle $script:MissedWindow })

# ---------------------------------------------------------------- 皮肤窗口
$script:SkinWindow = New-WindowFromXaml $xamlSkin
$script:SkinsPanel = $script:SkinWindow.FindName('SkinsPanel')
$script:SkinStatus = $script:SkinWindow.FindName('SkinStatus')
$script:SkinImport = $script:SkinWindow.FindName('SkinImport')
$script:SkinDefault = $script:SkinWindow.FindName('SkinDefault')
$script:SkinClose = $script:SkinWindow.FindName('SkinClose')
$script:SkinWindow.Add_SourceInitialized({ Set-ToolWindowStyle $script:SkinWindow })

# ---------------------------------------------------------------- 记忆窗口
$script:MemWindow = New-WindowFromXaml $xamlMemory
$script:MemStats = $script:MemWindow.FindName('MemStats')
$script:MemBody = $script:MemWindow.FindName('MemBody')
$script:FactsPanel = $script:MemWindow.FindName('FactsPanel')
$script:TodoPanel = $script:MemWindow.FindName('TodoPanel')
$script:SummariesText = $script:MemWindow.FindName('SummariesText')
$script:PersonaBox = $script:MemWindow.FindName('PersonaBox')
$script:MemStatus = $script:MemWindow.FindName('MemStatus')
$script:MemTodoInput = $script:MemWindow.FindName('MemTodoInput')
$script:MemTodoAdd = $script:MemWindow.FindName('MemTodoAdd')
$script:MemReflect = $script:MemWindow.FindName('MemReflect')
$script:MemSavePersona = $script:MemWindow.FindName('MemSavePersona')
$script:MemClose = $script:MemWindow.FindName('MemClose')
$script:MemWindow.Add_SourceInitialized({ Set-ToolWindowStyle $script:MemWindow })

# ============================================================================
#  冒泡
# ============================================================================
$script:BubbleTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:BubbleTimer.Interval = [TimeSpan]::FromSeconds(9)
$script:BubbleTimer.Add_Tick({
  $script:BubbleTimer.Stop()
  Hide-Bubble
})

function Hide-Bubble {
  $script:BubbleHost.Visibility = 'Collapsed'
  $script:BubbleHost.Opacity = 0
}

function Show-Bubble([string]$Text, [string]$Sub = '') {
  $script:BubbleText.Text = $Text
  if ([string]::IsNullOrWhiteSpace($Sub)) {
    $script:BubbleSub.Visibility = 'Collapsed'
  } else {
    $script:BubbleSub.Text = $Sub
    $script:BubbleSub.Visibility = 'Visible'
  }
  $script:BubbleHost.Visibility = 'Visible'
  $anim = New-Object System.Windows.Media.Animation.DoubleAnimation(0, 1, [TimeSpan]::FromMilliseconds(180))
  $script:BubbleHost.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $anim)
  $script:BubbleTimer.Stop()
  $script:BubbleTimer.Start()
}

function Get-StatusLine {
  $parts = @()
  if ($script:BalanceText) { $parts += $script:BalanceText }
  $tokens = [int]$script:Config.todayTokens
  if ($tokens -gt 0) { $parts += ("今天聊了 " + $tokens + " tokens") }
  return ($parts -join ' · ')
}

function Invoke-WhaleBounce {
  $down = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 0.92, [TimeSpan]::FromMilliseconds(90))
  $down.AutoReverse = $true
  $script:WhaleScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $down)
  $down2 = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 1.06, [TimeSpan]::FromMilliseconds(90))
  $down2.AutoReverse = $true
  $script:WhaleScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $down2)
}

# ============================================================================
#  聊天界面
# ============================================================================
function Add-ChatBubble {
  param([string]$Text, [string]$Kind = 'assistant')
  $b = New-Object System.Windows.Controls.Border
  $b.CornerRadius = [System.Windows.CornerRadius]::new(12)
  $b.Padding = [System.Windows.Thickness]::new(11, 7, 11, 7)
  $b.Margin = [System.Windows.Thickness]::new(4, 3, 4, 3)
  $b.MaxWidth = 320
  $tb = New-Object System.Windows.Controls.TextBlock
  $tb.Text = $Text
  $tb.TextWrapping = 'Wrap'
  $tb.FontSize = 13.2
  $tb.LineHeight = 19
  switch ($Kind) {
    'user' {
      $b.Background = Get-Brush '#2F7CF6'
      $tb.Foreground = [System.Windows.Media.Brushes]::White
      $b.HorizontalAlignment = 'Right'
    }
    'thinking' {
      $b.Background = Get-Brush '#F6F8FB'
      $tb.Foreground = Get-Brush '#8A97A8'
      $tb.FontStyle = 'Italic'
      $b.HorizontalAlignment = 'Left'
    }
    'system' {
      $b.Background = Get-Brush '#FFF7E8'
      $tb.Foreground = Get-Brush '#8A6A2F'
      $tb.FontSize = 12
      $tb.LineHeight = 17
      $b.HorizontalAlignment = 'Left'
    }
    default {
      $b.Background = Get-Brush '#F0F4FA'
      $tb.Foreground = Get-Brush '#1B2430'
      $b.HorizontalAlignment = 'Left'
    }
  }
  $b.Child = $tb
  $script:ChatPanel.Children.Add($b) | Out-Null
  $script:ChatScroll.UpdateLayout()
  $script:ChatScroll.ScrollToEnd()
  return $b
}

function Set-ChatBusy([bool]$Busy) {
  $script:ChatBusy = $Busy
  $script:ChatSend.IsEnabled = -not $Busy
  $script:ChatInput.IsEnabled = -not $Busy
  if (-not $Busy) { $script:ChatInput.Focus() | Out-Null }
}

function Update-ChatBalance {
  if ($script:ChatBalance) {
    $script:ChatBalance.Text = if ($script:BalanceText) { $script:BalanceText } else { '' }
  }
}

function Remove-ChatPlaceholder {
  if ($script:ChatPlaceholderBubble) {
    $script:ChatPanel.Children.Remove($script:ChatPlaceholderBubble) | Out-Null
    $script:ChatPlaceholderBubble = $null
  }
}

# ============================================================================
#  HTTP
# ============================================================================
$script:Http = New-Object System.Net.Http.HttpClient
$script:Http.Timeout = [TimeSpan]::FromSeconds(120)
$script:HttpTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:HttpTimer.Interval = [TimeSpan]::FromMilliseconds(120)

function Start-HttpTask {
  param($Request, [scriptblock]$OnDone)
  $id = [guid]::NewGuid().ToString('N')
  $task = $script:Http.SendAsync($Request)
  $script:Pending[$id] = @{ task = $task; onDone = $OnDone }
  $script:HttpTimer.Start()
}

$script:HttpTimer.Add_Tick({
  if ($script:Pending.Count -eq 0) { $script:HttpTimer.Stop(); return }
  foreach ($id in @($script:Pending.Keys)) {
    $item = $script:Pending[$id]
    if (-not $item.task.IsCompleted) { continue }
    $script:Pending.Remove($id)
    $status = -1
    $body = ''
    $resp = $null
    try {
      $resp = $item.task.GetAwaiter().GetResult()
      $status = [int]$resp.StatusCode
      $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    } catch {
      $body = 'ERR: ' + $_.Exception.GetBaseException().Message
    } finally {
      if ($resp) { $resp.Dispose() }
    }
    try { & $item.onDone $status $body } catch { Write-Log ("回调错误: " + $_.Exception.Message) }
  }
  if ($script:Pending.Count -eq 0) { $script:HttpTimer.Stop() }
})

function New-ApiRequest([string]$Method, [string]$Url, [string]$Key, [string]$JsonBody = '') {
  $m = [System.Net.Http.HttpMethod]::Get
  if ($Method -eq 'POST') { $m = [System.Net.Http.HttpMethod]::Post }
  $req = New-Object System.Net.Http.HttpRequestMessage($m, $Url)
  $req.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $Key)
  if ($JsonBody) {
    $req.Content = New-Object System.Net.Http.StringContent($JsonBody, [Text.Encoding]::UTF8, 'application/json')
  }
  return $req
}

# ============================================================================
#  余额
# ============================================================================
function Notify-BalanceLow([string]$Detail = '', [switch]$Force) {
  $now = Get-Date
  if (-not $Force) {
    if ($script:BalanceWarned) { return }
  } else {
    if ($script:LastBalanceWarnAt -and (($now - $script:LastBalanceWarnAt).TotalMinutes -lt 5)) { return }
  }
  $script:BalanceWarned = $true
  $script:LastBalanceWarnAt = $now
  $sub = if ($Detail) { $Detail } else { '去 platform.deepseek.com 充点值，我就能继续陪你' }
  Show-Bubble '余额不足啦～' $sub
  try {
    if ($script:Tray) { $script:Tray.ShowBalloonTip(8000, '小鲸鱼：余额不足', $sub, [System.Windows.Forms.ToolTipIcon]::Warning) }
  } catch { }
  Write-Log ('余额提醒: ' + $sub)
}

function Apply-BalanceValue([double]$Total, [string]$Currency) {
  $sym = if ($Currency -eq 'USD') { '$' } else { '¥' }
  $script:BalanceText = '余额 ' + $sym + $Total.ToString('0.00')
  $script:BalanceOk = $true
  $threshold = 5.0
  try { if ($script:Config.lowBalanceThreshold) { $threshold = [double]$script:Config.lowBalanceThreshold } } catch { }
  if ($Total -lt $threshold) {
    $script:BalanceWasLow = $true
    $script:Config.lastBalanceLow = $true
    Save-Config
    Notify-BalanceLow ('现在只剩 ' + $sym + $Total.ToString('0.00') + ' 了')
  } elseif ($script:BalanceWasLow) {
    $script:BalanceWasLow = $false
    $script:BalanceWarned = $false
    $script:LastBalanceWarnAt = $null
    $script:Config.lastBalanceLow = $false
    Save-Config
    Show-Bubble '余额回来啦～' ('现在 ' + $sym + $Total.ToString('0.00') + '，可以继续聊了')
    try {
      if ($script:Tray) { $script:Tray.ShowBalloonTip(6000, '小鲸鱼：余额恢复', '可以继续聊啦', [System.Windows.Forms.ToolTipIcon]::Info) }
    } catch { }
    Write-Log ('余额恢复: ' + $sym + $Total.ToString('0.00'))
  }
  Update-ChatBalance
}

function Refresh-Balance {
  $fake = $env:WHALEPET_FAKE_BALANCE
  if ($fake) {
    try { Apply-BalanceValue ([double]$fake) 'CNY' } catch { }
    return
  }
  $key = Get-ApiKey
  if ([string]::IsNullOrWhiteSpace($key)) { $script:BalanceText = ''; Update-ChatBalance; return }
  if ($script:BalanceBusy) { return }
  $script:BalanceBusy = $true
  $req = New-ApiRequest 'GET' 'https://api.deepseek.com/user/balance' $key
  Start-HttpTask $req {
    param($status, $body)
    $script:BalanceBusy = $false
    if ($status -eq 200) {
      try {
        $obj = $body | ConvertFrom-Json
        $infos = @($obj.balance_infos)
        if ($infos.Count -gt 0) {
          $info = $infos[0]
          Apply-BalanceValue ([double]$info.total_balance) ([string]$info.currency)
        } else {
          $script:BalanceText = ''
          $script:BalanceOk = $false
          Update-ChatBalance
        }
      } catch { Write-Log ("余额解析失败: " + $_.Exception.Message) }
    } elseif ($status -eq 401) {
      $script:BalanceText = 'Key 无效'
      $script:BalanceOk = $false
      Update-ChatBalance
    }
  }
}

$script:BalanceTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:BalanceTimer.Interval = [TimeSpan]::FromSeconds(90)
$script:BalanceTimer.Add_Tick({ Refresh-Balance })

# ============================================================================
#  工具执行
# ============================================================================
function Invoke-PetTool([string]$Name, [string]$ArgsJson) {
  $a = @{}
  if ($ArgsJson) {
    try {
      $o = $ArgsJson | ConvertFrom-Json
      foreach ($p in $o.PSObject.Properties) { $a[$p.Name] = $p.Value }
    } catch { }
  }
  try {
    switch ($Name) {
      'add_todo' {
        $todo = Add-Todo -Text ([string]$a['text']) -Due ([string]$a['due'])
        return (@{ ok = $true; todo = $todo.text; due = $todo.due } | ConvertTo-Json -Compress)
      }
      'complete_todo' {
        $t = Complete-Todo -Text ([string]$a['text'])
        if ($t) { return (@{ ok = $true; done = $t.text } | ConvertTo-Json -Compress) }
        return (@{ ok = $false; reason = '没找到这条待办' } | ConvertTo-Json -Compress)
      }
      'list_todos' {
        $items = @()
        foreach ($t in (Get-OpenTodos)) { $items += @{ text = $t.text; due = $t.due } }
        return (@{ ok = $true; todos = $items; count = $items.Count } | ConvertTo-Json -Depth 5 -Compress)
      }
      'remember' {
        $f = Add-Fact -Text ([string]$a['text']) -Source 'chat'
        return (@{ ok = $true; remembered = $f.text } | ConvertTo-Json -Compress)
      }
      'set_reminder' {
        $minutes = [int]$a['minutes']
        if ($minutes -lt 1) { $minutes = 1 }
        $at = (Get-Date).AddMinutes($minutes)
        $r = Add-Reminder -Text ([string]$a['text']) -At $at
        return (@{ ok = $true; at = $at.ToString('yyyy-MM-dd HH:mm') } | ConvertTo-Json -Compress)
      }
      'search_memory' {
        $hits = Search-Memory ([string]$a['query'])
        $items = @()
        foreach ($h in $hits) { $items += @{ kind = $h.kind; text = $h.text } }
        return (@{ ok = $true; hits = $items } | ConvertTo-Json -Depth 5 -Compress)
      }
      'get_current_time' {
        return (@{ ok = $true; now = (Get-Date).ToString('yyyy-MM-dd HH:mm dddd') } | ConvertTo-Json -Compress)
      }
      default {
        return (@{ ok = $false; reason = '未知工具' } | ConvertTo-Json -Compress)
      }
    }
  } catch {
    return (@{ ok = $false; reason = $_.Exception.Message } | ConvertTo-Json -Compress)
  }
}

# ============================================================================
#  聊天（带工具循环）
# ============================================================================
function Get-ChatErrorText([int]$Status, [string]$Body) {
  switch ($Status) {
    401 { return 'API Key 不对哦（401）～ 右键小鲸鱼 →「设置」重新填一下。' }
    402 { return '账户余额不足（402），去 platform.deepseek.com 充点再聊吧（我已经在桌面提醒你了）。' }
    429 { return '请求太频繁了（429），歇一小会儿再试。' }
    -1 { return '连不上 DeepSeek 服务器，检查一下网络再试～' }
    default {
      $snippet = $Body
      if ($snippet.Length -gt 160) { $snippet = $snippet.Substring(0, 160) }
      return ("出错了（" + $Status + "）：" + $snippet)
    }
  }
}

function Request-ChatRound {
  $ctx = $script:ChatCtx
  if (-not $ctx) { return }
  $model = [string]$script:Config.model
  if ([string]::IsNullOrWhiteSpace($model)) { $model = 'deepseek-chat' }
  $payload = @{
    model       = $model
    messages    = $ctx.messages
    tools       = (Get-ToolDefinitions)
    tool_choice = 'auto'
    temperature = 0.8
  } | ConvertTo-Json -Depth 40 -Compress

  $req = New-ApiRequest 'POST' 'https://api.deepseek.com/chat/completions' $ctx.key $payload
  Start-HttpTask $req {
    param($status, $body)
    Handle-ChatResponse $status $body
  }
}

function Handle-ChatResponse([int]$Status, [string]$Body) {
  $ctx = $script:ChatCtx
  if (-not $ctx) { return }
  if ($Status -ne 200) {
    if ($Status -eq 402) { Notify-BalanceLow '这条消息没发出去：账户余额不足（402）' -Force }
    if ($Status -eq 401) { Show-Bubble 'API Key 失效了' '右键我 →「设置」重新填一下' }
    Remove-ChatPlaceholder
    Add-ChatBubble (Get-ChatErrorText $Status $Body) 'system' | Out-Null
    Set-ChatBusy $false
    $script:ChatCtx = $null
    return
  }

  try { $obj = $Body | ConvertFrom-Json } catch {
    Remove-ChatPlaceholder
    Add-ChatBubble ('回复解析失败：' + $_.Exception.Message) 'system' | Out-Null
    Set-ChatBusy $false
    $script:ChatCtx = $null
    return
  }

  $msg = $obj.choices[0].message
  $toolCalls = @($msg.tool_calls)

  if ($toolCalls.Count -gt 0 -and $ctx.depth -lt 4) {
    $asst = @{ role = 'assistant'; content = ''; tool_calls = @() }
    foreach ($tc in $toolCalls) {
      $asst.tool_calls += @{
        id       = [string]$tc.id
        type     = 'function'
        function = @{ name = [string]$tc.function.name; arguments = [string]$tc.function.arguments }
      }
    }
    $ctx.messages += $asst
    foreach ($tc in $toolCalls) {
      $result = Invoke-PetTool ([string]$tc.function.name) ([string]$tc.function.arguments)
      $ctx.messages += @{ role = 'tool'; tool_call_id = [string]$tc.id; content = $result }
    }
    $ctx.depth++
    if ($script:ChatPlaceholderBubble) {
      $script:ChatPlaceholderBubble.Child.Text = '小鲸鱼正在处理…'
    }
    Request-ChatRound
    return
  }

  $reply = [string]$msg.content
  if ([string]::IsNullOrWhiteSpace($reply)) { $reply = '（这次没想出话来说…）' }
  Remove-ChatPlaceholder
  Add-ChatBubble $reply 'assistant' | Out-Null
  Set-ChatBusy $false
  $script:ChatCtx = $null

  Add-Turn -Role 'user' -Content $ctx.userText
  Add-Turn -Role 'assistant' -Content $reply
  $meta = Get-Meta
  $meta.userTurns = [int]$meta.userTurns + 1
  Save-Memory

  if ($obj.usage) {
    $today = (Get-Date).ToString('yyyy-MM-dd')
    if ($script:Config.todayDate -ne $today) {
      $script:Config.todayDate = $today
      $script:Config.todayTokens = 0
    }
    $script:Config.todayTokens = [int]$script:Config.todayTokens + [int]$obj.usage.total_tokens
    Save-Config
  }

  if (([int]$meta.userTurns - [int]$meta.lastExtractTurn) -ge 4) {
    $meta.lastExtractTurn = $meta.userTurns
    Save-Memory
    Invoke-MemoryExtraction
  }

  if (-not $script:ChatVisible) {
    Invoke-WhaleBounce
    Show-Bubble '消息来啦～' '双击我看回复'
  }
  Refresh-MemoryPanel
}

function Send-ChatMessage {
  if ($script:ChatBusy) { return }
  $text = $script:ChatInput.Text
  if ([string]::IsNullOrWhiteSpace($text)) { return }
  $text = $text.Trim()
  $script:ChatInput.Text = ''
  $script:ChatPlaceholder.Visibility = 'Visible'
  Add-ChatBubble $text 'user' | Out-Null

  $key = Get-ApiKey
  if ([string]::IsNullOrWhiteSpace($key)) {
    Add-ChatBubble '还没有 API Key 呢～ 右键小鲸鱼 →「设置」，把 sk- 开头的 Key 填进来就能聊天啦。' 'system' | Out-Null
    return
  }

  Set-ChatBusy $true
  $script:ChatPlaceholderBubble = Add-ChatBubble '小鲸鱼正在思考…' 'thinking'

  $messages = @()
  $messages += @{ role = 'system'; content = (Get-SystemPrompt (Get-MemoryDigest)) }
  foreach ($t in @(Get-RecentTurns 14)) {
    $messages += @{ role = $t.role; content = $t.content }
  }
  $messages += @{ role = 'user'; content = $text }

  $script:ChatCtx = @{ messages = $messages; depth = 0; key = $key; userText = $text }
  Request-ChatRound
}

# ============================================================================
#  记忆抽取 / 每日整理
# ============================================================================
function Invoke-MemoryExtraction {
  if ($script:Extracting) { return }
  $turns = @(Get-RecentTurns 12)
  if ($turns.Count -lt 4) { return }
  $key = Get-ApiKey
  if ([string]::IsNullOrWhiteSpace($key)) { return }
  $script:Extracting = $true

  $model = [string]$script:Config.model
  if ([string]::IsNullOrWhiteSpace($model)) { $model = 'deepseek-chat' }
  $payload = @{
    model       = $model
    messages    = (Get-ExtractionMessages (Get-TurnsText $turns 4000))
    temperature = 0.2
  } | ConvertTo-Json -Depth 20 -Compress

  $req = New-ApiRequest 'POST' 'https://api.deepseek.com/chat/completions' $key $payload
  Start-HttpTask $req {
    param($status, $body)
    $script:Extracting = $false
    if ($status -eq 402) { Notify-BalanceLow '记忆自动整理因为余额不足暂停了' -Force }
    if ($status -ne 200) { return }
    try {
      $obj = $body | ConvertFrom-Json
      $data = ConvertFrom-LooseJson ([string]$obj.choices[0].message.content)
      if (-not $data) { return }
      foreach ($f in @($data.facts)) {
        if ($f) { Add-Fact -Text ([string]$f) -Source 'auto' | Out-Null }
      }
      foreach ($t in @($data.todos)) {
        if ($t -and $t.text) { Add-Todo -Text ([string]$t.text) -Due ([string]$t.due) | Out-Null }
      }
      Write-Log ('记忆抽取完成: +facts ' + @($data.facts).Count + ' +todos ' + @($data.todos).Count)
      Refresh-MemoryPanel
    } catch { Write-Log ('记忆抽取失败: ' + $_.Exception.Message) }
  }
}

function Invoke-Reflection {
  param([switch]$Manual)
  if ($script:Reflecting) { return }
  $date = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd')
  $turns = @(Get-TurnsForDate $date)
  if ($turns.Count -eq 0 -and $Manual) {
    $date = (Get-Date).ToString('yyyy-MM-dd')
    $turns = @(Get-RecentTurns 40)
  }
  if ($turns.Count -lt 2) {
    if ($Manual) { Show-Bubble '还没什么可整理的' '先和我聊几句吧' }
    return
  }
  $key = Get-ApiKey
  if ([string]::IsNullOrWhiteSpace($key)) { return }
  $script:Reflecting = $true
  if ($script:MemWindow.IsVisible) { $script:MemStatus.Text = '整理中…' }

  $model = [string]$script:Config.model
  if ([string]::IsNullOrWhiteSpace($model)) { $model = 'deepseek-chat' }
  $payload = @{
    model       = $model
    messages    = (Get-ReflectionMessages $date (Get-TurnsText $turns 5000))
    temperature = 0.3
  } | ConvertTo-Json -Depth 20 -Compress

  $req = New-ApiRequest 'POST' 'https://api.deepseek.com/chat/completions' $key $payload
  Start-HttpTask $req {
    param($status, $body)
    $script:Reflecting = $false
    if ($status -ne 200) {
      if ($status -eq 402) { Notify-BalanceLow '每日整理因为余额不足暂停了' -Force }
      if ($script:MemWindow.IsVisible) { $script:MemStatus.Text = '整理失败（网络/Key/余额）' }
      return
    }
    try {
      $obj = $body | ConvertFrom-Json
      $data = ConvertFrom-LooseJson ([string]$obj.choices[0].message.content)
      if (-not $data) { if ($script:MemWindow.IsVisible) { $script:MemStatus.Text = '整理结果解析失败' }; return }
      if ($data.summary) { Add-Summary -Date $date -Text ([string]$data.summary) }
      if ($data.traits) { Add-PersonaTraits -Traits @($data.traits) }
      foreach ($f in @($data.facts)) { if ($f) { Add-Fact -Text ([string]$f) -Source 'reflection' | Out-Null } }
      Set-MetaReflection ((Get-Date).ToString('yyyy-MM-dd'))
      if ($script:MemWindow.IsVisible) { $script:MemStatus.Text = '整理完成 ✓'; Refresh-MemoryPanel }
      Show-Bubble '整理好啦～' '我把今天记下来了'
      Write-Log ('每日整理完成: ' + $date)
    } catch { Write-Log ('每日整理失败: ' + $_.Exception.Message) }
  }
}

# ============================================================================
#  记忆面板
# ============================================================================
function Refresh-MemoryPanel {
  if (-not $script:MemWindow) { return }
  $script:MemBuilding = $true
  try {
    $stats = Get-MemoryStats
    $script:MemStats.Text = ('事实 ' + $stats.facts + ' · 待办 ' + $stats.todos + ' · 摘要 ' + $stats.summaries + ' · 对话 ' + $stats.turns + ' 轮')

    $script:FactsPanel.Children.Clear()
    $facts = @((Get-Memory).facts)
    if ($facts.Count -eq 0) {
      $empty = New-Object System.Windows.Controls.TextBlock
      $empty.Text = '还没有记住什么，跟我聊聊你的喜好、习惯、正在做的项目吧。'
      $empty.FontSize = 11.5
      $empty.Foreground = Get-Brush '#A9B4C2'
      $empty.TextWrapping = 'Wrap'
      $empty.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
      [void]$script:FactsPanel.Children.Add($empty)
    } else {
      foreach ($f in $facts) {
        $row = New-Object System.Windows.Controls.DockPanel
        $row.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $f.text
        $tb.TextWrapping = 'Wrap'
        $tb.FontSize = 12
        $tb.Foreground = Get-Brush '#3F4B5B'
        $btn = New-Object System.Windows.Controls.Button
        $btn.Content = '✕'
        $btn.Tag = $f.id
        $btn.Style = $script:MemWindow.FindResource('XBtn')
        $btn.Add_Click({ param($s, $e) Remove-Fact ([string]$s.Tag); Refresh-MemoryPanel })
        [System.Windows.Controls.DockPanel]::SetDock($btn, 'Right')
        [void]$row.Children.Add($btn)
        [void]$row.Children.Add($tb)
        [void]$script:FactsPanel.Children.Add($row)
      }
    }

    $script:TodoPanel.Children.Clear()
    $todos = @((Get-Memory).todos)
    $open = @($todos | Where-Object { -not $_.done })
    if ($open.Count -eq 0) {
      $empty2 = New-Object System.Windows.Controls.TextBlock
      $empty2.Text = '没有待办。跟我说「记一下：明天交报告」试试。'
      $empty2.FontSize = 11.5
      $empty2.Foreground = Get-Brush '#A9B4C2'
      $empty2.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
      [void]$script:TodoPanel.Children.Add($empty2)
    } else {
      foreach ($t in $open) {
        $row = New-Object System.Windows.Controls.DockPanel
        $row.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
        $btn = New-Object System.Windows.Controls.Button
        $btn.Content = '✕'
        $btn.Tag = $t.id
        $btn.Style = $script:MemWindow.FindResource('XBtn')
        $btn.Add_Click({ param($s, $e) Remove-Todo ([string]$s.Tag); Refresh-MemoryPanel })
        [System.Windows.Controls.DockPanel]::SetDock($btn, 'Right')
        [void]$row.Children.Add($btn)

        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Tag = $t.id
        $cb.IsChecked = [bool]$t.done
        $cb.VerticalAlignment = 'Center'
        $cb.Margin = [System.Windows.Thickness]::new(0, 1, 6, 1)
        $cb.Add_Checked({ param($s, $e) if ($script:MemBuilding) { return }; Complete-Todo -Id ([string]$s.Tag) | Out-Null; Refresh-MemoryPanel })
        [System.Windows.Controls.DockPanel]::SetDock($cb, 'Left')
        [void]$row.Children.Add($cb)

        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $t.text
        $tb.TextWrapping = 'Wrap'
        $tb.FontSize = 12
        $tb.Foreground = Get-Brush '#3F4B5B'
        $tb.VerticalAlignment = 'Center'
        if ($t.due) { $tb.Text = $tb.Text + '（' + $t.due + '）' }
        [void]$row.Children.Add($tb)
        [void]$script:TodoPanel.Children.Add($row)
      }
    }

    $sums = @(Get-RecentSummaries 5)
    if ($sums.Count -eq 0) {
      $script:SummariesText.Text = '每晚会自动整理一次；也可以点右下角「整理记忆」马上做。'
      $script:SummariesText.Foreground = Get-Brush '#A9B4C2'
    } else {
      $lines = @()
      foreach ($s in $sums) { $lines += ($s.date + '：' + $s.text) }
      $script:SummariesText.Text = ($lines -join "`r`n`r`n")
      $script:SummariesText.Foreground = Get-Brush '#5B6B7F'
    }

    $script:PersonaBox.Text = (Get-PersonaText)
  } finally {
    $script:MemBuilding = $false
  }
}

function Show-MemoryPanel {
  if (-not $script:MemWindow.IsVisible) {
    Refresh-MemoryPanel
    $script:MemWindow.Show()
  }
  $script:MemWindow.Activate()
}

$script:MemClose.Add_Click({ $script:MemWindow.Hide() })
$script:MemSavePersona.Add_Click({
  Set-PersonaText ($script:PersonaBox.Text)
  $script:MemStatus.Text = '人设已保存 ✓'
})
$script:MemTodoAdd.Add_Click({
  $t = $script:MemTodoInput.Text
  if ([string]::IsNullOrWhiteSpace($t)) { return }
  Add-Todo -Text $t | Out-Null
  $script:MemTodoInput.Text = ''
  $script:MemStatus.Text = '已添加待办 ✓'
  Refresh-MemoryPanel
})
$script:MemTodoInput.Add_KeyDown({
  param($s, $e)
  if ($e.Key -eq 'Return') {
    $e.Handled = $true
    $t = $script:MemTodoInput.Text
    if ([string]::IsNullOrWhiteSpace($t)) { return }
    Add-Todo -Text $t | Out-Null
    $script:MemTodoInput.Text = ''
    $script:MemStatus.Text = '已添加待办 ✓'
    Refresh-MemoryPanel
  }
})
$script:MemReflect.Add_Click({
  $script:MemStatus.Text = '整理中…'
  Invoke-Reflection -Manual
})
$script:MemWindow.Add_KeyDown({
  param($s, $e)
  if ($e.Key -eq 'Escape') { $script:MemWindow.Hide() }
})

function Show-MissedReminders {
  $overdue = @(Get-DueReminders (Get-Date))
  if ($overdue.Count -eq 0) { return }

  $script:ReviewingMissed = $true
  $script:MissedPending = $overdue
  $script:MissedIds = @($overdue | ForEach-Object { $_.id })
  $script:MissedList.Children.Clear()
  $now = Get-Date
  foreach ($r in $overdue) {
    $at = [datetime]::Parse($r.at)
    $late = $now - $at
    $lateText = ''
    if ($late.TotalDays -ge 1) { $lateText = ([int]$late.TotalDays).ToString() + ' 天前' }
    elseif ($late.TotalHours -ge 1) { $lateText = ([int]$late.TotalHours).ToString() + ' 小时前' }
    else { $lateText = ([Math]::Max(1, [int]$late.TotalMinutes)).ToString() + ' 分钟前' }

    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = '⏰ ' + $at.ToString('MM-dd HH:mm') + '  ' + $r.text + '（' + $lateText + '到点）'
    $tb.TextWrapping = 'Wrap'
    $tb.FontSize = 12.5
    $tb.Foreground = Get-Brush '#3F4B5B'
    $tb.Margin = [System.Windows.Thickness]::new(0, 3, 0, 3)
    [void]$script:MissedList.Children.Add($tb)
  }
  $script:MissedSub.Text = ('有 ' + $overdue.Count + ' 条提醒在你关机或不在时到点了，要现在补发吗？')
  $script:MissedWindow.ShowDialog() | Out-Null
  $script:ReviewingMissed = $false
}

$script:MissedReplay.Add_Click({
  $items = @($script:MissedPending)
  foreach ($r in $items) { Mark-ReminderFired $r.id }
  $script:MissedPending = @()
  $script:MissedWindow.Close()
  if ($items.Count -eq 1) {
    Show-Bubble ('⏰ ' + $items[0].text) '这条提醒之前错过了'
  } elseif ($items.Count -gt 1) {
    $lines = @()
    foreach ($r in @($items | Select-Object -First 4)) { $lines += ('· ' + $r.text) }
    Show-Bubble ('补发 ' + $items.Count + ' 条提醒') ($lines -join "`n")
  }
  try {
    if ($script:Tray -and $items.Count -gt 0) {
      $script:Tray.ShowBalloonTip(8000, '小鲸鱼：补发提醒', (($items | ForEach-Object { $_.text }) -join '；'), [System.Windows.Forms.ToolTipIcon]::Info)
    }
  } catch { }
})

$script:MissedIgnore.Add_Click({
  foreach ($r in @($script:MissedPending)) { Mark-ReminderFired $r.id }
  $script:MissedPending = @()
  $script:MissedWindow.Close()
})

$script:MissedLater.Add_Click({ $script:MissedWindow.Close() })
$script:MissedWindow.Add_KeyDown({
  param($s, $e)
  if ($e.Key -eq 'Escape') { $script:MissedWindow.Close() }
})

# ============================================================================
#  设置窗口
# ============================================================================
function Show-Settings {
  $dlg = New-WindowFromXaml $xamlSettings
  $dlg.Topmost = $true
  if ($script:MainWindow.IsVisible) { $dlg.Owner = $script:MainWindow }
  $keyBox = $dlg.FindName('KeyBox')
  $modelBox = $dlg.FindName('ModelBox')
  $getBtn = $dlg.FindName('GetKeyBtn')
  $saveBtn = $dlg.FindName('SaveBtn')
  $cancelBtn = $dlg.FindName('CancelBtn')

  $keyBox.Password = Get-ApiKey
  $modelBox.Text = [string]$script:Config.model

  $script:DlgWindow = $dlg
  $script:DlgKeyBox = $keyBox
  $script:DlgModelBox = $modelBox

  $getBtn.Add_Click({ Start-Process 'https://platform.deepseek.com/api_keys' })
  $cancelBtn.Add_Click({ $script:DlgWindow.Close() })
  $saveBtn.Add_Click({
    $k = $script:DlgKeyBox.Password.Trim()
    $m = $script:DlgModelBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($m)) { $m = 'deepseek-chat' }
    $script:Config.apiKeyProtected = Protect-Text $k
    $script:Config.model = $m
    Save-Config
    $script:DlgWindow.Close()
    $script:BalanceText = ''
    Refresh-Balance
    if ($k) { Show-Bubble '设置好啦～' '试着和我聊一句？' } else { Show-Bubble '已清空 API Key' }
  })

  $dlg.ShowDialog() | Out-Null
}

# ============================================================================
#  交互
# ============================================================================
$script:DragStart = $null

$script:WhaleHost.Add_MouseLeftButtonDown({
  param($sender, $e)
  if ($e.ClickCount -eq 2) { Show-Chat; return }
  $script:DragStart = [System.Windows.Forms.Cursor]::Position
  try { $script:MainWindow.DragMove() } catch { }
  $end = [System.Windows.Forms.Cursor]::Position
  $dist = [Math]::Abs($end.X - $script:DragStart.X) + [Math]::Abs($end.Y - $script:DragStart.Y)
  Clamp-Window $script:MainWindow
  $script:Config.posX = [double]$script:MainWindow.Left
  $script:Config.posY = [double]$script:MainWindow.Top
  Save-Config
  if ($dist -lt 6) {
    Invoke-WhaleBounce
    $line = $script:IdleLines[(Get-Random -Maximum $script:IdleLines.Count)]
    $todos = (Get-MemoryStats).todos
    $sub = Get-StatusLine
    if ($todos -gt 0) { $sub = '还有 ' + $todos + ' 条待办 · ' + $sub }
    Show-Bubble $line $sub
  }
})

function New-MenuItem([string]$Header, [scriptblock]$Action, [bool]$Checkable = $false, [bool]$Checked = $false) {
  $mi = New-Object System.Windows.Controls.MenuItem
  $mi.Header = $Header
  if ($Checkable) { $mi.IsCheckable = $true; $mi.IsChecked = $Checked }
  if ($Action) { $mi.Add_Click($Action) }
  return $mi
}

$menu = New-Object System.Windows.Controls.ContextMenu
$miChat = New-MenuItem '和我聊天' { Show-Chat }
$miMemory = New-MenuItem '记忆与设定…' { Show-MemoryPanel }
$miTodos = New-MenuItem '我的待办' {
  $open = @(Get-OpenTodos)
  if ($open.Count -eq 0) { Show-Bubble '现在没有待办' '跟我说「记一下…」就行' }
  else {
    $lines = @()
    foreach ($t in @($open | Select-Object -First 5)) { $lines += ('· ' + $t.text) }
    Show-Bubble ($lines -join "`n") ('共 ' + $open.Count + ' 条 · 打开聊天可以细说')
  }
}
$miReflect = New-MenuItem '整理今天的记忆' { Invoke-Reflection -Manual }
$miRefresh = New-MenuItem '刷新余额' { Refresh-Balance; Show-Bubble '刷新余额中…' }
$miTop = New-MenuItem '始终置顶' {
  $script:Config.topmost = $miTop.IsChecked
  $script:MainWindow.Topmost = $miTop.IsChecked
  Save-Config
} $true ([bool]$script:Config.topmost)
$miAuto = New-MenuItem '开机自启' {
  $ok = Set-Autostart ([bool]$miAuto.IsChecked)
  if (-not $ok) {
    $miAuto.IsChecked = -not $miAuto.IsChecked
    Show-Bubble '设置开机自启失败' '可能是权限不够，试试以管理员身份运行一次'
  } else {
    $script:Config.autoStart = [bool]$miAuto.IsChecked
    Save-Config
  }
} $true ([bool]$script:Config.autoStart)
$miSettings = New-MenuItem '设置…' { Show-Settings }
$miSkin = New-MenuItem '换皮肤…' { Show-SkinPanel }
$miRestart = New-MenuItem '重启桌宠' { Restart-App }
$miFolder = New-MenuItem '打开数据文件夹' { Start-Process explorer.exe $script:DataDir }
$miExit = New-MenuItem '退出' { Exit-App }

$menu.Items.Add($miChat) | Out-Null
$menu.Items.Add($miMemory) | Out-Null
$menu.Items.Add($miTodos) | Out-Null
$menu.Items.Add($miReflect) | Out-Null
$menu.Items.Add($miRefresh) | Out-Null
$menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
$menu.Items.Add($miTop) | Out-Null
$menu.Items.Add($miAuto) | Out-Null
$menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
$menu.Items.Add($miSettings) | Out-Null
$menu.Items.Add($miSkin) | Out-Null
$menu.Items.Add($miRestart) | Out-Null
$menu.Items.Add($miFolder) | Out-Null
$menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
$menu.Items.Add($miExit) | Out-Null
$script:WhaleHost.ContextMenu = $menu

# ============================================================================
#  聊天窗口事件
# ============================================================================
function Show-Chat {
  if (-not $script:ChatWindow.IsVisible) {
    $wa = Get-WorkArea
    $left = $script:MainWindow.Left - $script:ChatWindow.Width - 6
    if ($left -lt $wa.Left) { $left = $script:MainWindow.Left + $script:MainWindow.Width + 6 }
    if ($left + $script:ChatWindow.Width -gt $wa.Right) { $left = $wa.Right - $script:ChatWindow.Width }
    $top = $script:MainWindow.Top
    $top = [Math]::Max($wa.Top, [Math]::Min($top, $wa.Bottom - $script:ChatWindow.Height))
    $script:ChatWindow.Left = $left
    $script:ChatWindow.Top = $top
    $script:ChatWindow.Show()
    $script:ChatVisible = $true
    if ($script:ChatPanel.Children.Count -eq 0) {
      $greet = '嗨，我是小鲸鱼～'
      if ([string]::IsNullOrWhiteSpace((Get-ApiKey))) {
        Add-ChatBubble '嗨，我是小鲸鱼～ 先右键我 →「设置」填一个 DeepSeek API Key，我们就能聊天了。' 'assistant' | Out-Null
      } else {
        $stats = Get-MemoryStats
        if ($stats.facts -gt 0 -or $stats.todos -gt 0) {
          $greet = '我回来啦～ 记得 ' + $stats.facts + ' 件事、' + $stats.todos + ' 条待办。今天想做什么？'
        } else {
          $greet = '嗨，我是小鲸鱼～ 今天想聊点什么？'
        }
        Add-ChatBubble $greet 'assistant' | Out-Null
      }
    }
    Refresh-Balance
  }
  $script:ChatWindow.Activate()
  $script:ChatInput.Focus() | Out-Null
}

$script:ChatClose.Add_Click({ $script:ChatWindow.Hide(); $script:ChatVisible = $false })
$script:ChatMemory.Add_Click({ Show-MemoryPanel })
$script:ChatSend.Add_Click({ Send-ChatMessage })
$script:ChatInput.Add_KeyDown({
  param($sender, $e)
  if ($e.Key -eq 'Return') { $e.Handled = $true; Send-ChatMessage }
})
$script:ChatInput.Add_TextChanged({
  if ($script:ChatInput.Text.Length -eq 0) { $script:ChatPlaceholder.Visibility = 'Visible' }
  else { $script:ChatPlaceholder.Visibility = 'Collapsed' }
})
$script:ChatHeader.Add_MouseLeftButtonDown({ try { $script:ChatWindow.DragMove() } catch { } })
$script:ChatWindow.Add_KeyDown({
  param($sender, $e)
  if ($e.Key -eq 'Escape') { $script:ChatWindow.Hide(); $script:ChatVisible = $false }
})

# ============================================================================
#  托盘
# ============================================================================
function Initialize-Tray {
  try {
    $bmp = New-Object System.Drawing.Bitmap($script:WhalePng)
    $hicon = $bmp.GetHicon()
    $script:TrayIconImage = [System.Drawing.Icon]::FromHandle($hicon)
    $tray = New-Object System.Windows.Forms.NotifyIcon
    $tray.Icon = $script:TrayIconImage
    $tray.Text = '小鲸鱼桌宠'
    $tray.Visible = $true

    $cms = New-Object System.Windows.Forms.ContextMenuStrip
    $iShow = New-Object System.Windows.Forms.ToolStripMenuItem('显示 / 隐藏小鲸鱼')
    $iShow.Add_Click({ if ($script:MainWindow.IsVisible) { $script:MainWindow.Hide() } else { $script:MainWindow.Show() } })
    $iChat = New-Object System.Windows.Forms.ToolStripMenuItem('和我聊天')
    $iChat.Add_Click({ Show-Chat })
    $iMem = New-Object System.Windows.Forms.ToolStripMenuItem('记忆与设定')
    $iMem.Add_Click({ Show-MemoryPanel })
    $iSkin = New-Object System.Windows.Forms.ToolStripMenuItem('换皮肤')
    $iSkin.Add_Click({ Show-SkinPanel })
    $iRefresh = New-Object System.Windows.Forms.ToolStripMenuItem('刷新余额')
    $iRefresh.Add_Click({ Refresh-Balance })
    $iExit = New-Object System.Windows.Forms.ToolStripMenuItem('退出')
    $iExit.Add_Click({ Exit-App })
    [void]$cms.Items.Add($iShow)
    [void]$cms.Items.Add($iChat)
    [void]$cms.Items.Add($iMem)
    [void]$cms.Items.Add($iSkin)
    [void]$cms.Items.Add($iRefresh)
    [void]$cms.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$cms.Items.Add($iExit)
    $tray.ContextMenuStrip = $cms
    $tray.Add_MouseDoubleClick({ Show-Chat })
    $script:Tray = $tray
    $script:TrayMenu = $cms
  } catch { Write-Log ("托盘图标创建失败: " + $_.Exception.Message) }
}

function Exit-App {
  try { Save-Config } catch { }
  try { if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() } } catch { }
  try { $script:MemWindow.Close() } catch { }
  try { $script:ChatWindow.Close() } catch { }
  try { $script:MainWindow.Close() } catch { }
  [System.Windows.Application]::Current.Shutdown()
}

function Restart-App {
  Save-Config
  try {
    $script:Restarting = $true
    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', (Join-Path $script:AppDir 'WhalePet.ps1')) -WindowStyle Hidden
  } catch { Write-Log ('重启失败: ' + $_.Exception.Message) }
  Exit-App
}

# ============================================================================
#  动画
# ============================================================================
function Start-IdleAnimations {
  $bob = New-Object System.Windows.Media.Animation.DoubleAnimation(0, -7, [TimeSpan]::FromSeconds(1.4))
  $bob.AutoReverse = $true
  $bob.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
  $bob.EasingFunction = New-Object System.Windows.Media.Animation.SineEase
  $bob.EasingFunction.EasingMode = 'EaseInOut'
  $script:WhaleMove.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $bob)

  $sway = New-Object System.Windows.Media.Animation.DoubleAnimation(-2.2, 2.2, [TimeSpan]::FromSeconds(2.6))
  $sway.AutoReverse = $true
  $sway.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
  $sway.EasingFunction = New-Object System.Windows.Media.Animation.SineEase
  $sway.EasingFunction.EasingMode = 'EaseInOut'
  $script:WhaleRotate.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $sway)
}

# ============================================================================
#  皮肤
# ============================================================================
function Get-GifDelay($Frame) {
  try {
    $d = $Frame.Metadata.GetQuery('/grctlext/Delay')
    if ($d -and [int]$d -gt 0) { return [TimeSpan]::FromMilliseconds([int]$d * 10) }
  } catch { }
  return [TimeSpan]::FromMilliseconds(100)
}

function Apply-Skin([string]$Id) {
  $path = Get-SkinPath $Id
  $script:GifTimer.Stop()
  $script:GifFrames = @()
  try {
    if ([System.IO.Path]::GetExtension($path).ToLowerInvariant() -eq '.gif') {
      $decoder = New-Object System.Windows.Media.Imaging.GifBitmapDecoder(
        (New-Object System.Uri($path)),
        [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
        [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
      $frames = @($decoder.Frames)
      if ($frames.Count -gt 0) {
        $script:GifFrames = $frames
        $script:GifIndex = 0
        $script:WhaleImage.Source = $frames[0]
        if ($frames.Count -gt 1) {
          $script:GifTimer.Interval = Get-GifDelay $frames[0]
          $script:GifTimer.Start()
        }
        return
      }
    }
  } catch { Write-Log ('GIF 加载失败: ' + $_.Exception.Message) }

  $bi = New-Object System.Windows.Media.Imaging.BitmapImage
  $bi.BeginInit()
  $bi.CacheOption = 'OnLoad'
  $bi.UriSource = New-Object System.Uri($path)
  $bi.EndInit()
  $script:WhaleImage.Source = $bi
}

$script:GifTimer.Add_Tick({
  if ($script:GifFrames.Count -lt 2) { $script:GifTimer.Stop(); return }
  $script:GifIndex = ($script:GifIndex + 1) % $script:GifFrames.Count
  $script:WhaleImage.Source = $script:GifFrames[$script:GifIndex]
  try { $script:GifTimer.Interval = Get-GifDelay $script:GifFrames[$script:GifIndex] } catch { }
})

function Get-SkinPreview($Id) {
  $path = Get-SkinPath $Id
  try {
    $bi = New-Object System.Windows.Media.Imaging.BitmapImage
    $bi.BeginInit()
    $bi.CacheOption = 'OnLoad'
    $bi.DecodePixelWidth = 72
    $bi.UriSource = New-Object System.Uri($path)
    $bi.EndInit()
    return $bi
  } catch { return $null }
}

function Refresh-SkinPanel {
  $script:SkinsPanel.Children.Clear()
  $activeId = Get-ActiveSkinId
  foreach ($s in Get-Skins) {
    $row = New-Object System.Windows.Controls.DockPanel
    $row.Margin = [System.Windows.Thickness]::new(0, 4, 0, 4)

    $img = New-Object System.Windows.Controls.Image
    $img.Width = 56
    $img.Height = 56
    $img.Stretch = 'Uniform'
    $img.Source = Get-SkinPreview $s.id
    [System.Windows.Controls.DockPanel]::SetDock($img, 'Left')
    [void]$row.Children.Add($img)

    $btns = New-Object System.Windows.Controls.StackPanel
    $btns.Orientation = 'Horizontal'
    $btns.VerticalAlignment = 'Center'
    [System.Windows.Controls.DockPanel]::SetDock($btns, 'Right')

    if ($s.id -eq $activeId) {
      $tag = New-Object System.Windows.Controls.TextBlock
      $tag.Text = '使用中'
      $tag.FontSize = 11.5
      $tag.Foreground = Get-Brush '#2F7CF6'
      $tag.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
      $tag.VerticalAlignment = 'Center'
      [void]$btns.Children.Add($tag)
    } else {
      $use = New-Object System.Windows.Controls.Button
      $use.Content = '使用'
      $use.Style = $script:SkinWindow.FindResource('GhostBtn')
      $use.Padding = [System.Windows.Thickness]::new(12, 5, 12, 5)
      $use.Tag = $s.id
      $use.Add_Click({
        param($sender, $e)
        $id = [string]$sender.Tag
        Set-ActiveSkinId $id
        Apply-Skin $id
        Refresh-SkinPanel
        Show-Bubble '换好皮肤啦～' ('现在用的是「' + (Get-SkinById $id).name + '」')
      })
      [void]$btns.Children.Add($use)
    }

    if (-not $s.builtin -and $s.id -ne 'default') {
      $del = New-Object System.Windows.Controls.Button
      $del.Content = '删除'
      $del.Style = $script:SkinWindow.FindResource('GhostBtn')
      $del.Padding = [System.Windows.Thickness]::new(10, 5, 10, 5)
      $del.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
      $del.Tag = $s.id
      $del.Add_Click({
        param($sender, $e)
        $id = [string]$sender.Tag
        $wasActive = ((Get-ActiveSkinId) -eq $id)
        Remove-Skin $id | Out-Null
        if ($wasActive) { Apply-Skin (Get-ActiveSkinId) }
        Refresh-SkinPanel
        Show-Bubble '删掉啦' '已切回默认皮肤'
      })
      [void]$btns.Children.Add($del)
    }
    [void]$row.Children.Add($btns)

    $name = New-Object System.Windows.Controls.TextBlock
    $name.Text = $s.name
    $name.FontSize = 13
    $name.Foreground = Get-Brush '#3F4B5B'
    $name.VerticalAlignment = 'Center'
    $name.Margin = [System.Windows.Thickness]::new(14, 0, 10, 0)
    $name.TextWrapping = 'Wrap'
    [void]$row.Children.Add($name)

    [void]$script:SkinsPanel.Children.Add($row)
  }
  $active = Get-SkinById $activeId
  if ($active) { $script:SkinStatus.Text = ('当前：' + $active.name) }
}

function Show-SkinPanel {
  Refresh-SkinPanel
  if (-not $script:SkinWindow.IsVisible) { $script:SkinWindow.Show() }
  $script:SkinWindow.Activate()
}

$script:SkinClose.Add_Click({ $script:SkinWindow.Hide() })
$script:SkinDefault.Add_Click({
  Set-ActiveSkinId 'default'
  Apply-Skin 'default'
  Refresh-SkinPanel
  Show-Bubble '已恢复默认皮肤'
})
$script:SkinImport.Add_Click({
  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $dlg.Title = '选择皮肤图片'
  $dlg.Filter = '图片 (*.png;*.gif;*.jpg;*.jpeg)|*.png;*.gif;*.jpg;*.jpeg'
  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    try {
      $rec = Add-Skin $dlg.FileName
      Set-ActiveSkinId $rec.id
      Apply-Skin $rec.id
      Refresh-SkinPanel
      Show-Bubble '换上新皮肤啦～' ('「' + $rec.name + '」')
    } catch {
      Show-Bubble '皮肤导入失败' ($_.Exception.Message)
    }
  }
})
$script:SkinWindow.Add_KeyDown({
  param($s, $e)
  if ($e.Key -eq 'Escape') { $script:SkinWindow.Hide() }
})

# ============================================================================
#  提醒
# ============================================================================
$script:ReminderTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:ReminderTimer.Interval = [TimeSpan]::FromSeconds(20)
$script:ReminderTimer.Add_Tick({
  if ($script:ReviewingMissed) { return }
  $due = Get-DueReminders (Get-Date)
  foreach ($r in $due) {
    if ($script:MissedIds -contains $r.id) { continue }
    Mark-ReminderFired $r.id
    Show-Bubble ('⏰ ' + $r.text) '到点啦'
    try {
      if ($script:Tray) { $script:Tray.ShowBalloonTip(6000, '小鲸鱼提醒', $r.text, [System.Windows.Forms.ToolTipIcon]::Info) }
    } catch { }
  }
})

# ============================================================================
#  启动
# ============================================================================
$script:App = New-Object System.Windows.Application
$script:App.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$script:App.Add_DispatcherUnhandledException({
  param($s, $e)
  Write-Log ('UI 异常: ' + $e.Exception.ToString())
  $e.Handled = $true
})

$script:MainWindow.Add_Loaded({
  Write-Log 'Loaded: begin'
  Save-Config
  Apply-Skin (Get-ActiveSkinId)
  Start-IdleAnimations
  Initialize-Tray
  $script:BalanceTimer.Start()
  $script:ReminderTimer.Start()
  Write-Log 'Loaded: timers started'

  $stats = Get-MemoryStats
  if ($script:FreshMemory) {
    Show-Bubble '我现在会记事啦～' '跟我说「记一下：…」试试'
  } elseif ($stats.todos -gt 0) {
    Show-Bubble ('你还有 ' + $stats.todos + ' 条待办哦') '双击我看看 · 右键有记忆面板'
  } elseif ([string]::IsNullOrWhiteSpace((Get-ApiKey))) {
    Show-Bubble '右键我 →「设置」' '填入 DeepSeek API Key，就能和我聊天啦'
  } else {
    Show-Bubble '我回来啦～' (Get-StatusLine)
  }
  if (-not [string]::IsNullOrWhiteSpace((Get-ApiKey))) { Refresh-Balance }

  Show-MissedReminders

  $meta = Get-Meta
  $today = (Get-Date).ToString('yyyy-MM-dd')
  if ([string]$meta.lastReflection -ne $today) {
    $yesterday = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd')
    if (@(Get-TurnsForDate $yesterday).Count -ge 2) {
      Invoke-Reflection
    } else {
      Set-MetaReflection $today
    }
  }

  if ($env:WHALEPET_OPEN_MEMORY -eq '1') { Show-MemoryPanel }
  if ($env:WHALEPET_OPEN_SKINS -eq '1') { Show-SkinPanel }
  if ($env:WHALEPET_OPEN_CHAT -eq '1' -or $env:WHALEPET_SEND_TEST) {
    $script:AutoTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:AutoTimer.Interval = [TimeSpan]::FromMilliseconds(800)
    $script:AutoTimer.Add_Tick({
      $script:AutoTimer.Stop()
      Show-Chat
      if ($env:WHALEPET_SEND_TEST) {
        $script:ChatInput.Text = $env:WHALEPET_SEND_TEST
        Send-ChatMessage
      }
    })
    $script:AutoTimer.Start()
  }
})

try {
  $script:App.Run($script:MainWindow) | Out-Null
} catch {
  Write-Log ("FATAL: " + $_.Exception.ToString())
} finally {
  try { if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() } } catch { }
  try { $script:Mutex.ReleaseMutex() } catch { }
  Write-Log '=== 退出 ==='
}
