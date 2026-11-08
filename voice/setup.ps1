# 一键准备语音环境（Python 依赖 + Whisper 模型）
# 需要：Python 3.10+（在 PATH 里，或设置 $env:WHALE_PY 指向 python.exe）
$ErrorActionPreference = 'Stop'
$base = Split-Path $PSScriptRoot -Parent
$venv = Join-Path $base 'voice\.venv'
$modelRoot = Join-Path $base 'voice\models\whisper'
$mirror = 'https://mirrors.aliyun.com/pypi/simple/'
$hfMirror = 'https://hf-mirror.com'

$py = $env:WHALE_PY
if (-not $py) {
  $cmd = Get-Command python -ErrorAction SilentlyContinue
  if ($cmd) { $py = $cmd.Source }
}
if (-not $py) {
  $dshPy = Join-Path $env:USERPROFILE '.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe'
  if (Test-Path $dshPy) { $py = $dshPy }
}
if (-not $py) { throw '找不到 Python，请先安装 Python 3.10+ 或设置 $env:WHALE_PY' }

if (-not (Test-Path (Join-Path $venv 'Scripts\python.exe'))) {
  & $py -m venv $venv
}
$vp = Join-Path $venv 'Scripts\python.exe'

Write-Host '[1/3] 安装 Python 依赖...'
& $vp -m pip install --disable-pip-version-check --no-cache-dir -i $mirror --trusted-host mirrors.aliyun.com faster-whisper sounddevice numpy zhconv

Write-Host '[2/3] 修补 PyAV 兼容性...'
$audio = Join-Path $venv 'Lib\site-packages\faster_whisper\audio.py'
if (Test-Path $audio) {
  $t = Get-Content $audio -Raw -Encoding UTF8
  $t = $t.Replace(', metadata_errors="ignore"', '').Replace(", metadata_errors='ignore'", '')
  [System.IO.File]::WriteAllText($audio, $t, [System.Text.UTF8Encoding]::new($false))
}

Write-Host '[3/3] 下载 Whisper small 模型（约 460MB，走 hf-mirror）...'
$env:HF_ENDPOINT = $hfMirror
$env:HF_HUB_DISABLE_XET = '1'
$env:HF_HUB_OFFLINE = '0'
& $vp -c "from faster_whisper import WhisperModel; WhisperModel('small', device='cpu', compute_type='int8', download_root=r'$modelRoot')"
Write-Host '完成。重启桌宠，右键开启「语音唤醒」。'
