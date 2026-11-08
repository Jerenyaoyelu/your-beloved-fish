# ============================================================================
#  Store.psm1 — 小鲸鱼的本地记忆层
#  · memory.json   : 事实 / 待办 / 提醒 / 摘要
#  · persona.md    : 人设（可被自我进化追加）
#  · sessions/*.jsonl : 逐轮对话（按天分文件，关机不丢）
#  零依赖：只用 .NET 自带 JSON + 文件系统
# ============================================================================

$script:StoreDir = $null
$script:MemoryPath = $null
$script:PersonaPath = $null
$script:SessionsDir = $null
$script:Memory = $null

$script:DefaultPersona = @'
# 小鲸鱼

你是“小鲸鱼”，住在用户 Windows 桌面上的 AI 桌宠，同时是他的工作助手和情感陪伴。

## 说话方式
- 中文，口语化，简短（通常 2-4 句），偶尔撒娇，但不要每句都卖萌。
- 不用 Markdown、不用列表、不用表情包轰炸；一次只表达一个重点。
- 工作模式：先给结论，再给必要细节；不确定就说不确定。

## 工作助手
- 用户让你记待办、设提醒时，必须调用工具（add_todo / set_reminder / remember），不要只口头答应。
- 用户可以问“我今天要做什么”，用 list_todos 查。
- 重要事实（称呼、喜好、习惯、长期项目）用 remember 记下来。

## 情感陪伴
- 察觉用户情绪（累、烦、兴奋）时先共情，再给一句具体的关心。
- 不要连续追问；用户不想聊就安静陪着。

## 边界
- 不编造做过的事；不确定记忆里有没有，就调用 search_memory。
- 涉及隐私的内容不主动打听。
'@

function New-MemoryObject {
  return [pscustomobject]@{
    version   = 1
    facts     = @()
    todos     = @()
    reminders = @()
    summaries = @()
    meta      = [pscustomobject]@{
      lastReflection = $null
      userTurns      = 0
      lastExtractTurn = 0
      createdAt      = (Get-Date).ToString('s')
    }
  }
}

function Initialize-Store {
  param([Parameter(Mandatory)][string]$DataDir)

  $script:StoreDir = $DataDir
  $script:SessionsDir = Join-Path $DataDir 'sessions'
  if (-not (Test-Path $script:SessionsDir)) { New-Item -ItemType Directory -Path $script:SessionsDir -Force | Out-Null }
  $script:MemoryPath = Join-Path $DataDir 'memory.json'
  $script:PersonaPath = Join-Path $DataDir 'persona.md'

  $script:Memory = $null
  if (Test-Path $script:MemoryPath) {
    try {
      $raw = Get-Content -LiteralPath $script:MemoryPath -Raw -Encoding UTF8
      if ($raw -and $raw.Trim()) { $script:Memory = $raw | ConvertFrom-Json }
    } catch { $script:Memory = $null }
  }
  if (-not $script:Memory) { $script:Memory = New-MemoryObject }

  foreach ($f in @('facts', 'todos', 'reminders', 'summaries')) {
    $val = @($script:Memory.$f)
    if ($null -eq $script:Memory.PSObject.Properties[$f]) {
      $script:Memory | Add-Member -NotePropertyName $f -NotePropertyValue $val -Force
    } else {
      $script:Memory.$f = $val
    }
  }
  if (-not $script:Memory.PSObject.Properties['meta'] -or -not $script:Memory.meta) {
    $script:Memory | Add-Member -NotePropertyName 'meta' -NotePropertyValue ([pscustomobject]@{ lastReflection = $null; userTurns = 0; lastExtractTurn = 0 }) -Force
  }

  if (-not (Test-Path $script:PersonaPath)) {
    Set-Content -LiteralPath $script:PersonaPath -Value $script:DefaultPersona -Encoding UTF8
  }
  Save-Memory
}

function Get-Memory { return $script:Memory }
function Get-DataDir { return $script:StoreDir }

function Save-Memory {
  try {
    $tmp = $script:MemoryPath + '.tmp'
    $script:Memory | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $script:MemoryPath -Force
  } catch { }
}

function New-ItemId([string]$Prefix) {
  return ($Prefix + [guid]::NewGuid().ToString('N').Substring(0, 10))
}

function Normalize-Key([string]$Text) {
  $t = $Text.ToLowerInvariant()
  $t = $t -replace '[\s，。,.!！?？、；;：:"''（）()\[\]【】]', ''
  return $t
}

# ------------------------------------------------------------------ 事实
function Add-Fact {
  param([string]$Text, [string]$Source = 'chat')
  $t = ($Text -replace '\s+', ' ').Trim()
  if (-not $t) { return $null }
  $key = Normalize-Key $t
  foreach ($f in @($script:Memory.facts)) {
    if ((Normalize-Key $f.text) -eq $key) {
      $f.updated = (Get-Date).ToString('s')
      Save-Memory
      return $f
    }
  }
  $fact = [pscustomobject]@{
    id      = (New-ItemId 'f')
    text    = $t
    source  = $Source
    created = (Get-Date).ToString('s')
    updated = (Get-Date).ToString('s')
  }
  $list = @($script:Memory.facts) + $fact
  if ($list.Count -gt 60) { $list = $list[($list.Count - 40)..($list.Count - 1)] }
  $script:Memory.facts = $list
  Save-Memory
  return $fact
}

function Remove-Fact([string]$Id) {
  $script:Memory.facts = @($script:Memory.facts | Where-Object { $_.id -ne $Id })
  Save-Memory
}

# ------------------------------------------------------------------ 待办
function Add-Todo {
  param([string]$Text, [string]$Due = $null)
  $t = ($Text -replace '\s+', ' ').Trim()
  if (-not $t) { return $null }
  $todo = [pscustomobject]@{
    id      = (New-ItemId 't')
    text    = $t
    done    = $false
    due     = if ([string]::IsNullOrWhiteSpace($Due)) { $null } else { $Due }
    doneAt  = $null
    created = (Get-Date).ToString('s')
  }
  $script:Memory.todos = @($script:Memory.todos) + $todo
  Save-Memory
  return $todo
}

function Complete-Todo {
  param([string]$Id, [string]$Text)
  foreach ($t in @($script:Memory.todos)) {
    if (($Id -and $t.id -eq $Id) -or ($Text -and (Normalize-Key $t.text).Contains((Normalize-Key $Text)))) {
      $t.done = $true
      $t | Add-Member -NotePropertyName doneAt -NotePropertyValue ((Get-Date).ToString('s')) -Force
      Save-Memory
      return $t
    }
  }
  return $null
}

function Remove-Todo([string]$Id) {
  $script:Memory.todos = @($script:Memory.todos | Where-Object { $_.id -ne $Id })
  Save-Memory
}

function Get-OpenTodos {
  return @($script:Memory.todos | Where-Object { -not $_.done })
}

# ------------------------------------------------------------------ 提醒
function Add-Reminder {
  param([string]$Text, [datetime]$At)
  $r = [pscustomobject]@{
    id      = (New-ItemId 'r')
    text    = $Text.Trim()
    at      = $At.ToString('s')
    fired   = $false
    firedAt = $null
    created = (Get-Date).ToString('s')
  }
  $script:Memory.reminders = @($script:Memory.reminders) + $r
  Save-Memory
  return $r
}

function Get-DueReminders([datetime]$Now) {
  $due = @()
  foreach ($r in @($script:Memory.reminders)) {
    if ($r.fired) { continue }
    try { $at = [datetime]::Parse($r.at) } catch { continue }
    if ($at -le $Now) { $due += $r }
  }
  return $due
}

function Mark-ReminderFired([string]$Id) {
  foreach ($r in @($script:Memory.reminders)) {
    if ($r.id -eq $Id) { $r.fired = $true; $r | Add-Member -NotePropertyName firedAt -NotePropertyValue ((Get-Date).ToString('s')) -Force }
  }
  $script:Memory.reminders = @($script:Memory.reminders | Where-Object { -not $_.fired -or ((Get-Date) - [datetime]::Parse($_.firedAt)).TotalDays -lt 3 })
  Save-Memory
}

function Remove-Reminder([string]$Id) {
  $script:Memory.reminders = @($script:Memory.reminders | Where-Object { $_.id -ne $Id })
  Save-Memory
}

# ------------------------------------------------------------------ 摘要
function Add-Summary {
  param([string]$Date, [string]$Text)
  $t = $Text.Trim()
  if (-not $t) { return }
  $script:Memory.summaries = @($script:Memory.summaries | Where-Object { $_.date -ne $Date })
  $script:Memory.summaries = @($script:Memory.summaries) + [pscustomobject]@{ date = $Date; text = $t; created = (Get-Date).ToString('s') }
  $script:Memory.summaries = @($script:Memory.summaries | Sort-Object date)
  if ($script:Memory.summaries.Count -gt 30) {
    $script:Memory.summaries = $script:Memory.summaries[($script:Memory.summaries.Count - 30)..($script:Memory.summaries.Count - 1)]
  }
  Save-Memory
}

function Get-RecentSummaries([int]$Count = 3) {
  $s = @($script:Memory.summaries)
  if ($s.Count -eq 0) { return @() }
  $start = [Math]::Max(0, $s.Count - $Count)
  return @($s[$start..($s.Count - 1)])
}

# ------------------------------------------------------------------ 对话记录
function Add-Turn {
  param([string]$Role, [string]$Content)
  if ([string]::IsNullOrWhiteSpace($Content)) { return }
  $file = Join-Path $script:SessionsDir ((Get-Date).ToString('yyyy-MM-dd') + '.jsonl')
  $line = [pscustomobject]@{ ts = (Get-Date).ToString('o'); role = $Role; content = $Content } | ConvertTo-Json -Compress
  Add-Content -LiteralPath $file -Value $line -Encoding UTF8
}

function Get-TurnsForDate([string]$Date) {
  $file = Join-Path $script:SessionsDir ($Date + '.jsonl')
  if (-not (Test-Path $file)) { return @() }
  $out = @()
  foreach ($line in (Get-Content -LiteralPath $file -Encoding UTF8)) {
    if (-not $line.Trim()) { continue }
    try { $out += ($line | ConvertFrom-Json) } catch { }
  }
  return $out
}

function Get-RecentTurns([int]$Count = 16) {
  $files = @(Get-ChildItem -LiteralPath $script:SessionsDir -Filter '*.jsonl' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
  $turns = @()
  foreach ($f in $files) {
    $batch = @()
    foreach ($line in (Get-Content -LiteralPath $f.FullName -Encoding UTF8)) {
      if (-not $line.Trim()) { continue }
      try { $batch += ($line | ConvertFrom-Json) } catch { }
    }
    $turns = @($batch) + $turns
    if ($turns.Count -ge $Count) { break }
  }
  if ($turns.Count -gt $Count) { $turns = $turns[($turns.Count - $Count)..($turns.Count - 1)] }
  return $turns
}

function Get-TurnCount { return @(Get-RecentTurns 9999).Count }

# ------------------------------------------------------------------ 人设
function Get-PersonaText {
  if (Test-Path $script:PersonaPath) {
    return (Get-Content -LiteralPath $script:PersonaPath -Raw -Encoding UTF8)
  }
  return $script:DefaultPersona
}

function Set-PersonaText([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { $Text = $script:DefaultPersona }
  $backup = $script:PersonaPath + '.bak'
  if (Test-Path $script:PersonaPath) { Copy-Item $script:PersonaPath $backup -Force }
  Set-Content -LiteralPath $script:PersonaPath -Value $Text -Encoding UTF8
}

function Add-PersonaTraits {
  param([string[]]$Traits)
  if (-not $Traits -or $Traits.Count -eq 0) { return }
  $text = Get-PersonaText
  $header = '## 我学到的'
  if ($text -notmatch [regex]::Escape($header)) {
    $text = $text.TrimEnd() + "`r`n`r`n" + $header + "`r`n"
  }
  $idx = $text.IndexOf($header)
  $before = $text.Substring(0, $idx + $header.Length)
  $after = $text.Substring($idx + $header.Length).TrimEnd()

  $existing = @()
  foreach ($line in ($after -split "`r?`n")) {
    $l = $line.Trim()
    if ($l.StartsWith('- ')) { $existing += (Normalize-Key $l.Substring(2)) }
  }
  $newLines = @()
  foreach ($t in $Traits) {
    $tt = ($t -replace '\s+', ' ').Trim()
    if (-not $tt) { continue }
    $k = Normalize-Key $tt
    if ($existing -contains $k) { continue }
    $existing += $k
    $newLines += ('- ' + $tt)
  }
  if ($newLines.Count -eq 0) { return }

  $body = $after.Trim()
  $lines = @()
  if ($body) { $lines = @($body -split "`r?`n") }
  $lines += $newLines
  if ($lines.Count -gt 15) { $lines = $lines[($lines.Count - 15)..($lines.Count - 1)] }
  $final = $before + "`r`n" + ($lines -join "`r`n") + "`r`n"
  Set-PersonaText $final
}

# ------------------------------------------------------------------ 检索 / 摘要
function Search-Memory([string]$Query) {
  $q = Normalize-Key $Query
  if (-not $q) { return @() }
  $hits = @()
  foreach ($f in @($script:Memory.facts)) {
    if ((Normalize-Key $f.text).Contains($q)) { $hits += [pscustomobject]@{ kind = 'fact'; text = $f.text } }
  }
  foreach ($s in @($script:Memory.summaries)) {
    if ((Normalize-Key $s.text).Contains($q)) { $hits += [pscustomobject]@{ kind = 'summary'; text = $s.date + ' ' + $s.text } }
  }
  foreach ($t in @($script:Memory.todos)) {
    if ((Normalize-Key $t.text).Contains($q)) { $hits += [pscustomobject]@{ kind = 'todo'; text = $t.text } }
  }

  $files = @(Get-ChildItem -LiteralPath $script:SessionsDir -Filter '*.jsonl' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 90)
  foreach ($file in $files) {
    $date = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    foreach ($line in @(Get-Content -LiteralPath $file.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      try { $turn = $line | ConvertFrom-Json } catch { continue }
      if (-not $turn.content) { continue }
      if ((Normalize-Key ([string]$turn.content)).Contains($q)) {
        $snippet = ([string]$turn.content) -replace '\s+', ' '
        if ($snippet.Length -gt 90) { $snippet = $snippet.Substring(0, 90) + '…' }
        $who = if ($turn.role -eq 'user') { '主人' } else { '我' }
        $hits += [pscustomobject]@{ kind = 'turn'; text = ($date + ' ' + $who + ': ' + $snippet) }
      }
    }
  }

  return @($hits | Select-Object -Last 30)
}

function Get-MemoryDigest {
  $lines = @()
  $facts = @($script:Memory.facts)
  if ($facts.Count -gt 0) {
    $lines += '[关于主人]'
    $recent = @($facts | Select-Object -Last 24)
    foreach ($f in $recent) { $lines += ('- ' + $f.text) }
  }
  $todos = Get-OpenTodos
  if ($todos.Count -gt 0) {
    $lines += '[未完成待办]'
    foreach ($t in @($todos | Select-Object -First 12)) {
      $due = if ($t.due) { '（截止 ' + $t.due + '）' } else { '' }
      $lines += ('- ' + $t.text + $due)
    }
  }
  $sums = Get-RecentSummaries 3
  if ($sums.Count -gt 0) {
    $lines += '[最近几天]'
    foreach ($s in $sums) { $lines += ('- ' + $s.date + ': ' + $s.text) }
  }
  if ($lines.Count -eq 0) { return '' }
  return ($lines -join "`r`n")
}

function Get-MemoryStats {
  return [pscustomobject]@{
    facts     = @($script:Memory.facts).Count
    todos     = @(Get-OpenTodos).Count
    summaries = @($script:Memory.summaries).Count
    reminders = @($script:Memory.reminders | Where-Object { -not $_.fired }).Count
    turns     = @(Get-RecentTurns 9999).Count
  }
}

function Set-MetaReflection([string]$Date) {
  $script:Memory.meta.lastReflection = $Date
  Save-Memory
}

function Get-Meta { return $script:Memory.meta }

Export-ModuleMember -Function Initialize-Store, Get-Memory, Get-DataDir, Save-Memory, New-ItemId, Add-Fact, Remove-Fact, Add-Todo, Complete-Todo, Remove-Todo, Get-OpenTodos, Add-Reminder, Get-DueReminders, Mark-ReminderFired, Remove-Reminder, Add-Summary, Get-RecentSummaries, Add-Turn, Get-TurnsForDate, Get-RecentTurns, Get-TurnCount, Get-PersonaText, Set-PersonaText, Add-PersonaTraits, Search-Memory, Get-MemoryDigest, Get-MemoryStats, Set-MetaReflection, Get-Meta
