param(
  [string]$WakeWord = '小鲸鱼',
  [Parameter(Mandatory)][string]$OutFile,
  [int]$Seconds = 600,
  [string]$WavPath = ''
)
$ErrorActionPreference = 'Stop'

try {
  Add-Type -AssemblyName System.Speech

  $phrases = [string[]]@($WakeWord, ('你好' + $WakeWord), ('嘿' + $WakeWord))
  $engine = New-Object System.Speech.Recognition.SpeechRecognitionEngine([System.Globalization.CultureInfo]'zh-CN')
  $choices = New-Object System.Speech.Recognition.Choices
  $choices.Add($phrases)
  $builder = New-Object System.Speech.Recognition.GrammarBuilder
  $builder.Append($choices)
  $grammar = New-Object System.Speech.Recognition.Grammar($builder)
  $engine.LoadGrammar($grammar)

  if ($WavPath) {
    $engine.SetInputToWaveFile($WavPath)
  } else {
    $engine.SetInputToDefaultAudioDevice()
  }

  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    $result = $engine.Recognize([TimeSpan]::FromSeconds(5))
    if ($result -and $result.Confidence -ge 0.55) {
      [System.IO.File]::WriteAllText($OutFile, $result.Text, [System.Text.UTF8Encoding]::new($false))
      exit 0
    }
    if ($WavPath) { break }
  }
  exit 2
} catch {
  try {
    [System.IO.File]::WriteAllText($OutFile, ('ERR:' + $_.Exception.Message), [System.Text.UTF8Encoding]::new($false))
  } catch { }
  exit 1
}
