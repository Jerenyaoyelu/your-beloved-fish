param(
  [Parameter(Mandatory)][string]$ImagePath,
  [Parameter(Mandatory)][string]$OutPath
)
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Runtime.WindowsRuntime

$null = [Windows.Media.Ocr.OcrEngine,Windows.Foundation,ContentType=WindowsRuntime]
$null = [Windows.Graphics.Imaging.SoftwareBitmap,Windows.Foundation,ContentType=WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapPixelFormat,Windows.Foundation,ContentType=WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapAlphaMode,Windows.Foundation,ContentType=WindowsRuntime]
$null = [Windows.Media.Ocr.OcrResult,Windows.Foundation,ContentType=WindowsRuntime]

$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
  $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]

function Await($op, $type) {
  $task = $asTask.MakeGenericMethod($type).Invoke($null, @($op))
  $task.Wait(-1) | Out-Null
  return $task.Result
}

$bmp = [System.Drawing.Bitmap]::FromFile($ImagePath)
$w = $bmp.Width
$h = $bmp.Height
$rect = New-Object System.Drawing.Rectangle 0, 0, $w, $h
$data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$bytes = New-Object byte[] ($w * 4 * $h)
for ($y = 0; $y -lt $h; $y++) {
  $src = [IntPtr]::Add($data.Scan0, $y * $data.Stride)
  [System.Runtime.InteropServices.Marshal]::Copy($src, $bytes, $y * $w * 4, $w * 4)
}
$bmp.UnlockBits($data)
$bmp.Dispose()

$buf = [System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions]::AsBuffer($bytes)
$sb = [Windows.Graphics.Imaging.SoftwareBitmap]::CreateCopyFromBuffer(
  $buf,
  [Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8,
  $w, $h,
  [Windows.Graphics.Imaging.BitmapAlphaMode]::Premultiplied)

$engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
if (-not $engine) { throw 'OCR engine unavailable' }
$result = Await ($engine.RecognizeAsync($sb)) ([Windows.Media.Ocr.OcrResult])
$text = [string]$result.Text
# 中文 OCR 会在汉字之间插空格，去掉
$text = $text -replace '(?<=[\u4e00-\u9fff])\s+(?=[\u4e00-\u9fff])', ''

[System.IO.File]::WriteAllText($OutPath, $text, [System.Text.UTF8Encoding]::new($false))
