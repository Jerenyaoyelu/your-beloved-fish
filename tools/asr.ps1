param(
  [Parameter(Mandatory)][string]$OutPath,
  [int]$Seconds = 12,
  [string]$WavPath = ''
)
$ErrorActionPreference = 'Stop'

try {
  Add-Type -AssemblyName System.Speech

  $engine = New-Object System.Speech.Recognition.SpeechRecognitionEngine([System.Globalization.CultureInfo]'zh-CN')
  $engine.LoadGrammar((New-Object System.Speech.Recognition.DictationGrammar))

  if ($WavPath) {
    if (-not (Test-Path $WavPath)) { throw '找不到测试音频' }
    $engine.SetInputToWaveFile($WavPath)
  } else {
    $engine.SetInputToDefaultAudioDevice()
  }

  $result = $engine.Recognize([TimeSpan]::FromSeconds($Seconds))
  $text = ''
  if ($result) { $text = [string]$result.Text }
  [System.IO.File]::WriteAllText($OutPath, $text, [System.Text.UTF8Encoding]::new($false))
  $engine.Dispose()
  exit 0
} catch {
  try {
    [System.IO.File]::WriteAllText($OutPath, ('ERR:' + $_.Exception.Message), [System.Text.UTF8Encoding]::new($false))
  } catch { }
  exit 1
}
