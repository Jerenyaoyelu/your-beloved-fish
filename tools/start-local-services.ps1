# ============================================================================
#  启动小鲸鱼依赖的本地服务
#  8080 Qwen2.5-VL 视觉 / 8081 Qwen3-Embedding / 1933 OpenViking
#  用法：powershell -ExecutionPolicy Bypass -File tools\start-local-services.ps1
# ============================================================================
param(
  [string]$RuntimeRoot = 'C:\Users\ASUS\Documents\deepseek-harness\default-workspace\whale-pet'
)

$ErrorActionPreference = 'Stop'

function Test-Port([int]$Port) {
  try {
    $client = New-Object System.Net.Sockets.TcpClient
    $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne(500)
    if ($ok) { $client.EndConnect($iar) }
    $client.Close()
    return $ok
  } catch { return $false }
}

$qv = Join-Path $RuntimeRoot 'voice\models\qwen-vl'
$llama = Join-Path $qv 'llama\llama-server.exe'
$visionModel = Join-Path $qv 'Qwen2.5-VL-3B-Instruct-Q4_K_M.gguf'
$mmproj = Join-Path $qv 'mmproj-F16.gguf'
$embedModel = Join-Path $qv 'Qwen3-Embedding-0.6B-Q8_0.gguf'
$ovExe = Join-Path $RuntimeRoot 'openviking\.venv\Scripts\openviking-server.exe'
$ovConf = Join-Path $env:USERPROFILE '.openviking\ov.conf'

foreach ($p in @($llama, $visionModel, $mmproj, $embedModel, $ovExe, $ovConf)) {
  if (-not (Test-Path $p)) { throw "缺少文件：$p" }
}

if (-not (Test-Port 8080)) {
  Write-Host '[start] vision :8080'
  Start-Process -FilePath $llama -ArgumentList @(
    '-m', $visionModel, '--mmproj', $mmproj, '-ngl', '99',
    '--host', '127.0.0.1', '--port', '8080', '-c', '8192', '--no-warmup'
  ) -RedirectStandardOutput (Join-Path $qv 'vision-server.log') `
    -RedirectStandardError (Join-Path $qv 'vision-server.log.err') -WindowStyle Hidden
} else { Write-Host '[skip] vision :8080 already running' }

if (-not (Test-Port 8081)) {
  Write-Host '[start] embedding :8081'
  Start-Process -FilePath $llama -ArgumentList @(
    '-m', $embedModel, '--embeddings', '--pooling', 'mean', '-ngl', '99',
    '--host', '127.0.0.1', '--port', '8081', '-c', '2048', '--no-warmup'
  ) -RedirectStandardOutput (Join-Path $qv 'embedding-server.log') `
    -RedirectStandardError (Join-Path $qv 'embedding-server.log.err') -WindowStyle Hidden
} else { Write-Host '[skip] embedding :8081 already running' }

if (-not (Test-Port 1933)) {
  Write-Host '[start] openviking :1933'
  $env:OPENVIKING_CONFIG_FILE = $ovConf
  Start-Process -FilePath $ovExe -RedirectStandardOutput (Join-Path $RuntimeRoot 'openviking\server.log') `
    -RedirectStandardError (Join-Path $RuntimeRoot 'openviking\server.log.err') -WindowStyle Hidden
} else { Write-Host '[skip] openviking :1933 already running' }

Write-Host '[wait] health checks...'
$deadline = (Get-Date).AddSeconds(90)
$ports = @{ 8080 = 'vision'; 8081 = 'embedding'; 1933 = 'openviking' }
while ((Get-Date) -lt $deadline) {
  $pending = @($ports.Keys | Where-Object { -not (Test-Port $_) })
  if ($pending.Count -eq 0) { break }
  Start-Sleep -Seconds 2
}
foreach ($port in $ports.Keys) {
  $ok = Test-Port $port
  Write-Host ("[{0}] {1} :{2}" -f $(if ($ok) { 'ok' } else { 'FAIL' }), $ports[$port], $port)
}
if (@($ports.Keys | Where-Object { -not (Test-Port $_) }).Count -gt 0) { exit 1 }
