# ============================================================================
#  小鲸鱼桌宠 (Whale Pet) — 独立运行的 Windows 桌面挂件
#  · 始终置顶、透明无边框、可拖拽、点击冒泡、双击聊天
#  · 聊天走 DeepSeek API（OpenAI 兼容 /chat/completions）
#  · 用 PowerShell 5.1 + WPF 实现，不需要安装任何东西
#  启动：双击 启动小鲸鱼.vbs（无控制台窗口）
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

# ---------------------------------------------------------------- 路径 & 日志
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

Write-Log ("=== 启动，数据目录: " + $script:DataDir + " ===")

trap {
  $logFile = 'C:\Users\ASUS\Documents\deepseek-harness\default-workspace\whale-pet\data\fatal.log'
  try { [System.IO.File]::AppendAllText($logFile, ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "  FATAL: " + $_.Exception.ToString() + "`r`n")) } catch { }
  try { [System.Windows.MessageBox]::Show(($_.Exception.Message + "`n`n详细信息见 `n" + $logFile), '小鲸鱼启动失败') | Out-Null } catch { }
  exit 1
}

# ---------------------------------------------------------------- 单实例
$script:Mutex = New-Object System.Threading.Mutex($false, 'Local\DeepSeekWhalePet')
try {
  if (-not $script:Mutex.WaitOne(0)) {
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
#  XAML — 主窗口（透明置顶的小鲸鱼）
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
        Title="和小鲸鱼聊天" Width="404" Height="566"
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
$script:FirstRun = -not (Test-Path $script:ConfigPath)
$script:BalanceText = ''
$script:BalanceOk = $false
$script:BalanceBusy = $false
$script:Pending = @{}
$script:ChatHistory = @()
$script:ChatBusy = $false
$script:ChatPlaceholderBubble = $null
$script:ChatVisible = $false
$script:IdleLines = @(
  '在呢在呢～', '摸摸头～', '今天也辛苦啦', '要不要聊两句？',
  '点我干嘛呀，嘿嘿', '我一直在这儿哦', '喝口水休息一下嘛', '嘿！'
)
$script:SystemPrompt = '你是住在用户 Windows 桌面上的小鲸鱼桌宠，名字叫“小鲸鱼”。你说话简短、可爱、有点黏人，用中文回答，一般一到三句话，不要用 Markdown 排版，不要长篇大论。'

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

$script:MainWindow.Add_SourceInitialized({
  Set-ToolWindowStyle $script:MainWindow
})

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
$script:ChatBalance = $script:ChatWindow.FindName('ChatBalance')

$script:ChatWindow.Add_SourceInitialized({
  Set-ToolWindowStyle $script:ChatWindow
})

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
  $b.MaxWidth = 300
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

# ============================================================================
#  HTTP（HttpClient + DispatcherTimer，避免后台线程跑脚本）
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
function Refresh-Balance {
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
          $cur = [string]$info.currency
          $sym = if ($cur -eq 'USD') { '$' } else { '¥' }
          $script:BalanceText = '余额 ' + $sym + ([double]$info.total_balance).ToString('0.00')
          $script:BalanceOk = $true
        } else {
          $script:BalanceText = ''
          $script:BalanceOk = $false
        }
      } catch { Write-Log ("余额解析失败: " + $_.Exception.Message) }
    } elseif ($status -eq 401) {
      $script:BalanceText = 'Key 无效'
      $script:BalanceOk = $false
    } else {
      $script:BalanceOk = $false
    }
    Update-ChatBalance
  }
}

$script:BalanceTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:BalanceTimer.Interval = [TimeSpan]::FromSeconds(90)
$script:BalanceTimer.Add_Tick({ Refresh-Balance })

# ============================================================================
#  聊天发送
# ============================================================================
function Get-ChatErrorText([int]$Status, [string]$Body) {
  switch ($Status) {
    401 { return 'API Key 不对哦（401）～ 右键小鲸鱼 →「设置」重新填一下。' }
    402 { return '账户余额不足（402），去 platform.deepseek.com 充点再聊吧。' }
    429 { return '请求太频繁了（429），歇一小会儿再试。' }
    -1 { return '连不上 DeepSeek 服务器，检查一下网络再试～' }
    default {
      $snippet = $Body
      if ($snippet.Length -gt 160) { $snippet = $snippet.Substring(0, 160) }
      return ("出错了（" + $Status + "）：" + $snippet)
    }
  }
}

function Send-ChatMessage {
  if ($script:ChatBusy) { return }
  $text = $script:ChatInput.Text
  if ([string]::IsNullOrWhiteSpace($text)) { return }
  $text = $text.Trim()
  $script:ChatInput.Text = ''
  $script:ChatPlaceholder.Visibility = 'Visible'
  Add-ChatBubble $text 'user' | Out-Null
  $script:ChatHistory += @{ role = 'user'; content = $text }

  $key = Get-ApiKey
  if ([string]::IsNullOrWhiteSpace($key)) {
    Add-ChatBubble '还没有 API Key 呢～ 右键小鲸鱼 →「设置」，把 sk- 开头的 Key 填进来就能聊天啦。' 'system' | Out-Null
    return
  }

  Set-ChatBusy $true
  $script:ChatPlaceholderBubble = Add-ChatBubble '小鲸鱼正在思考…' 'thinking'

  $msgs = @()
  $msgs += @{ role = 'system'; content = $script:SystemPrompt }
  foreach ($m in ($script:ChatHistory | Select-Object -Last 12)) {
    $msgs += @{ role = $m.role; content = $m.content }
  }
  $model = [string]$script:Config.model
  if ([string]::IsNullOrWhiteSpace($model)) { $model = 'deepseek-chat' }
  $payload = @{
    model       = $model
    messages    = $msgs
    stream      = $false
    temperature = 1.0
  } | ConvertTo-Json -Depth 10 -Compress

  $req = New-ApiRequest 'POST' 'https://api.deepseek.com/chat/completions' $key $payload
  Start-HttpTask $req {
    param($status, $body)
    if ($script:ChatPlaceholderBubble) {
      $script:ChatPanel.Children.Remove($script:ChatPlaceholderBubble) | Out-Null
      $script:ChatPlaceholderBubble = $null
    }
    Set-ChatBusy $false
    if ($status -eq 200) {
      try {
        $obj = $body | ConvertFrom-Json
        $reply = [string]$obj.choices[0].message.content
        if ([string]::IsNullOrWhiteSpace($reply)) { $reply = '（这次没想出话来说…）' }
        Add-ChatBubble $reply 'assistant' | Out-Null
        $script:ChatHistory += @{ role = 'assistant'; content = $reply }
        if ($obj.usage) {
          $today = (Get-Date).ToString('yyyy-MM-dd')
          if ($script:Config.todayDate -ne $today) {
            $script:Config.todayDate = $today
            $script:Config.todayTokens = 0
          }
          $script:Config.todayTokens = [int]$script:Config.todayTokens + [int]$obj.usage.total_tokens
          Save-Config
        }
      } catch {
        Add-ChatBubble ('回复解析失败：' + $_.Exception.Message) 'system' | Out-Null
      }
    } else {
      Add-ChatBubble (Get-ChatErrorText $status $body) 'system' | Out-Null
    }
    if (-not $script:ChatVisible) {
      Invoke-WhaleBounce
      Show-Bubble '消息来啦～' '双击我看回复'
    }
  }
}

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
  if ($e.ClickCount -eq 2) {
    Show-Chat
    return
  }
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
    Show-Bubble $line (Get-StatusLine)
  }
})

# ---------------------------------------------------------------- 右键菜单
function New-MenuItem([string]$Header, [scriptblock]$Action, [bool]$Checkable = $false, [bool]$Checked = $false) {
  $mi = New-Object System.Windows.Controls.MenuItem
  $mi.Header = $Header
  if ($Checkable) {
    $mi.IsCheckable = $true
    $mi.IsChecked = $Checked
  }
  if ($Action) { $mi.Add_Click($Action) }
  return $mi
}

$menu = New-Object System.Windows.Controls.ContextMenu
$miChat = New-MenuItem '和我聊天' { Show-Chat }
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
$miFolder = New-MenuItem '打开数据文件夹' { Start-Process explorer.exe $script:DataDir }
$miExit = New-MenuItem '退出' { Exit-App }

$menu.Items.Add($miChat) | Out-Null
$menu.Items.Add($miRefresh) | Out-Null
$menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
$menu.Items.Add($miTop) | Out-Null
$menu.Items.Add($miAuto) | Out-Null
$menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
$menu.Items.Add($miSettings) | Out-Null
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
    $top = $script:MainWindow.Top + 30
    $top = [Math]::Max($wa.Top, [Math]::Min($top, $wa.Bottom - $script:ChatWindow.Height))
    $script:ChatWindow.Left = $left
    $script:ChatWindow.Top = $top
    $script:ChatWindow.Show()
    $script:ChatVisible = $true
    if ($script:ChatPanel.Children.Count -eq 0) {
      if ([string]::IsNullOrWhiteSpace((Get-ApiKey))) {
        Add-ChatBubble '嗨，我是小鲸鱼～ 先右键我 →「设置」填一个 DeepSeek API Key，我们就能聊天了。' 'assistant' | Out-Null
      } else {
        Add-ChatBubble '嗨，我是小鲸鱼～ 今天想聊点什么？' 'assistant' | Out-Null
      }
    }
    Refresh-Balance
  }
  $script:ChatWindow.Activate()
  $script:ChatInput.Focus() | Out-Null
}

$script:ChatClose.Add_Click({ $script:ChatWindow.Hide(); $script:ChatVisible = $false })
$script:ChatSend.Add_Click({ Send-ChatMessage })
$script:ChatInput.Add_KeyDown({
  param($sender, $e)
  if ($e.Key -eq 'Return') {
    $e.Handled = $true
    Send-ChatMessage
  }
})
$script:ChatInput.Add_TextChanged({
  if ($script:ChatInput.Text.Length -eq 0) {
    $script:ChatPlaceholder.Visibility = 'Visible'
  } else {
    $script:ChatPlaceholder.Visibility = 'Collapsed'
  }
})
$script:ChatHeader.Add_MouseLeftButtonDown({
  try { $script:ChatWindow.DragMove() } catch { }
})
$script:ChatWindow.Add_KeyDown({
  param($sender, $e)
  if ($e.Key -eq 'Escape') { $script:ChatWindow.Hide(); $script:ChatVisible = $false }
})

# ============================================================================
#  托盘图标
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
    $iShow.Add_Click({
      if ($script:MainWindow.IsVisible) { $script:MainWindow.Hide() } else { $script:MainWindow.Show() }
    })
    $iChat = New-Object System.Windows.Forms.ToolStripMenuItem('和我聊天')
    $iChat.Add_Click({ Show-Chat })
    $iRefresh = New-Object System.Windows.Forms.ToolStripMenuItem('刷新余额')
    $iRefresh.Add_Click({ Refresh-Balance })
    $iExit = New-Object System.Windows.Forms.ToolStripMenuItem('退出')
    $iExit.Add_Click({ Exit-App })
    [void]$cms.Items.Add($iShow)
    [void]$cms.Items.Add($iChat)
    [void]$cms.Items.Add($iRefresh)
    [void]$cms.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$cms.Items.Add($iExit)
    $tray.ContextMenuStrip = $cms
    $tray.Add_MouseDoubleClick({ Show-Chat })
    $script:Tray = $tray
    $script:TrayMenu = $cms
  } catch {
    Write-Log ("托盘图标创建失败: " + $_.Exception.Message)
  }
}

function Exit-App {
  try { Save-Config } catch { }
  try { if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() } } catch { }
  try { $script:ChatWindow.Close() } catch { }
  try { $script:MainWindow.Close() } catch { }
  [System.Windows.Application]::Current.Shutdown()
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
#  启动
# ============================================================================
$script:App = New-Object System.Windows.Application
$script:App.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown

$script:MainWindow.Add_Loaded({
  Write-Log 'Loaded: begin'
  Save-Config
  Start-IdleAnimations
  Write-Log 'Loaded: animations started'
  Initialize-Tray
  Write-Log 'Loaded: tray done'
  $script:BalanceTimer.Start()
  Write-Log 'Loaded: timer started'

  if ($script:FirstRun) {
    Save-Config
    Show-Bubble '嗨！我是小鲸鱼～' '拖我换位置 · 点我冒泡 · 双击聊天 · 右键有菜单'
  } elseif ([string]::IsNullOrWhiteSpace((Get-ApiKey))) {
    Show-Bubble '右键我 →「设置」' '填入 DeepSeek API Key，就能和我聊天啦'
  } else {
    Refresh-Balance
    Show-Bubble '我回来啦～' (Get-StatusLine)
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
