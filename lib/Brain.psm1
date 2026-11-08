# ============================================================================
#  Brain.psm1 — 提示词、工具定义、记忆抽取/反思提示
# ============================================================================

function Get-ToolDefinitions {
  return @(
    @{
      type     = 'function'
      function = @{
        name        = 'add_todo'
        description = '给用户新增一条待办事项。当用户说“记一下/帮我记着/我要做…”时调用。'
        parameters  = @{
          type       = 'object'
          properties = @{
            text = @{ type = 'string'; description = '待办内容，一句话' }
            due  = @{ type = 'string'; description = '可选的截止时间，格式 yyyy-MM-dd HH:mm；不确定就留空' }
          }
          required   = @('text')
        }
      }
    },
    @{
      type     = 'function'
      function = @{
        name        = 'complete_todo'
        description = '把一条待办标记为完成。'
        parameters  = @{
          type       = 'object'
          properties = @{
            text = @{ type = 'string'; description = '待办的关键词或原文' }
          }
          required   = @('text')
        }
      }
    },
    @{
      type     = 'function'
      function = @{
        name        = 'list_todos'
        description = '列出当前未完成的待办。'
        parameters  = @{ type = 'object'; properties = @{}; required = @() }
      }
    },
    @{
      type     = 'function'
      function = @{
        name        = 'remember'
        description = '长期记住一条关于用户的事实（称呼、偏好、习惯、长期项目、重要的人）。'
        parameters  = @{
          type       = 'object'
          properties = @{
            text = @{ type = 'string'; description = '一条不超过 50 字的事实' }
          }
          required   = @('text')
        }
      }
    },
    @{
      type     = 'function'
      function = @{
        name        = 'set_reminder'
        description = '设置一个到点提醒，桌宠会在时间到时冒泡。'
        parameters  = @{
          type       = 'object'
          properties = @{
            text    = @{ type = 'string'; description = '提醒内容' }
            minutes = @{ type = 'integer'; description = '多少分钟后提醒，最小 1' }
          }
          required   = @('text', 'minutes')
        }
      }
    },
    @{
      type     = 'function'
      function = @{
        name        = 'search_memory'
        description = '在长期记忆里搜索关键词，不确定以前聊过什么时使用。'
        parameters  = @{
          type       = 'object'
          properties = @{
            query = @{ type = 'string'; description = '关键词' }
          }
          required   = @('query')
        }
      }
    },
    @{
      type     = 'function'
      function = @{
        name        = 'read_file'
        description = '读取工作区里的一个文本文件（相对路径或工作区内的绝对路径），返回前 8000 个字符。'
        parameters  = @{
          type       = 'object'
          properties = @{
            path = @{ type = 'string'; description = '文件路径，相对于工作区或工作区内绝对路径' }
          }
          required   = @('path')
        }
      }
    },
    @{
      type     = 'function'
      function = @{
        name        = 'list_dir'
        description = '列出工作区里某个目录的文件和子目录。'
        parameters  = @{
          type       = 'object'
          properties = @{
            path = @{ type = 'string'; description = '目录路径，留空表示工作区根目录' }
          }
          required   = @()
        }
      }
    },
    @{
      type     = 'function'
      function = @{
        name        = 'propose_dsh'
        description = '当你不确定用户是想让你真的执行，还是只想问做法/建议时，先调用它征求确认；用户确认后，下一轮再调用 delegate_to_dsh。'
        parameters  = @{
          type       = 'object'
          properties = @{
            task     = @{ type = 'string'; description = '准备交给 DSH 的任务' }
            question = @{ type = 'string'; description = '问用户的一句话，例如“要我直接在项目里改吗？”' }
          }
          required   = @('task')
        }
      }
    },
    @{
      type     = 'function'
      function = @{
        name        = 'open_app'
        description = '打开本机白名单里的应用或网站。用户说“打开浏览器/打开记事本/打开B站”时调用。'
        parameters  = @{
          type       = 'object'
          properties = @{
            name = @{ type = 'string'; description = '应用或网站名，如 浏览器、记事本、计算器、B站、知乎' }
          }
          required   = @('name')
        }
      }
    },
    @{
      type     = 'function'
      function = @{
        name        = 'open_url'
        description = '用默认浏览器打开一个 http/https 网址。'
        parameters  = @{
          type       = 'object'
          properties = @{
            url = @{ type = 'string'; description = '完整网址' }
          }
          required   = @('url')
        }
      }
    },
    @{
      type     = 'function'
      function = @{
        name        = 'search_web'
        description = '在百度搜索一个关键词并打开浏览器。'
        parameters  = @{
          type       = 'object'
          properties = @{
            query = @{ type = 'string'; description = '搜索关键词' }
          }
          required   = @('query')
        }
      }
    },
    @{
      type     = 'function'
      function = @{
        name        = 'delegate_to_dsh'
        description = '把需要实际执行的工作任务（读写文件、跑命令、查代码、调研、多步骤操作）交给本机 DSH 处理。闲聊、情感陪伴、简单问答不要调用。调用后任务在后台执行，结果会自动发到聊天；回复时只说已交给 DSH，不要声称已完成。'
        parameters  = @{
          type       = 'object'
          properties = @{
            task = @{ type = 'string'; description = '完整、可独立执行的任务描述，包含必要的路径和上下文' }
          }
          required   = @('task')
        }
      }
    },
    @{
      type     = 'function'
      function = @{
        name        = 'get_current_time'
        description = '获取当前日期和时间。'
        parameters  = @{ type = 'object'; properties = @{}; required = @() }
      }
    }
  )
}

function Get-SystemPrompt {
  param([string]$Digest = '')

  $persona = Get-PersonaText
  $parts = @()
  $parts += $persona.TrimEnd()
  $parts += ''
  $parts += ('当前时间：' + (Get-Date).ToString('yyyy-MM-dd HH:mm') + '（' + (Get-DayOfWeekName) + '）')
  if ($Digest) {
    $parts += ''
    $parts += '==== 长期记忆（自动注入，聊天时自然使用，不要逐条复述） ===='
    $parts += $Digest
  }
  $parts += ''
  $parts += '工具规则：用户让你记待办/设提醒/记住事实时，先调用对应工具，再简短确认；不要假装已经记住。'
  $parts += '工作规则：凡是需要实际动手的任务（读写文件、跑命令、查代码、调研、多步骤操作），必须调用 delegate_to_dsh 交给本机 DSH 执行，不要自己假装完成，也不要只给建议；闲聊、情感陪伴、简单问答不要调用。调用后只回复「已经交给 DSH，完成后告诉你」，绝对不要声称任务已完成或编造结果——结果会在几秒后自动出现在聊天里。'
  $parts += '如果用户只是问怎么做、或者你不确定他是否真的要你动手，先调用 propose_dsh 问一句确认，不要直接执行。'
  $parts += '要打开应用、网址或搜索时，调用 open_app / open_url / search_web；只能打开白名单里的应用，打不开就如实说，不要编造已经打开。'
  return ($parts -join "`r`n")
}

function Get-DayOfWeekName {
  $n = (Get-Date).DayOfWeek
  switch ($n) {
    'Monday' { return '周一' }
    'Tuesday' { return '周二' }
    'Wednesday' { return '周三' }
    'Thursday' { return '周四' }
    'Friday' { return '周五' }
    'Saturday' { return '周六' }
    default { return '周日' }
  }
}

function Get-ExtractionMessages {
  param([string]$TurnsText)
  $sys = @'
你是小鲸鱼的记忆整理器。根据对话片段，抽取值得长期保留的信息。
只输出 JSON，不要解释，不要 Markdown 代码块。格式：
{"facts":["..."],"todos":[{"text":"...","due":null}]}
规则：
- facts：关于用户的稳定信息（称呼、偏好、习惯、长期项目、重要的人），每条不超过 40 字；没有就空数组。
- todos：用户明确说要做、但还没做的事；没有就空数组。
- 不要记录寒暄、一次性的情绪、小鲸鱼自己说过的话。
- 无法确定的信息不要写。
'@
  return @(
    @{ role = 'system'; content = $sys },
    @{ role = 'user'; content = "对话片段：`r`n" + $TurnsText }
  )
}

function Get-ReflectionMessages {
  param([string]$Date, [string]$TurnsText)
  $sys = @'
你是小鲸鱼的记忆整理器。下面是某一天的对话，请做一次“每日整理”。
只输出 JSON，不要解释，不要 Markdown 代码块。格式：
{"summary":"2-4 句话，总结用户今天做了什么、状态如何","traits":["关于用户的稳定特征或偏好，每条一句话，最多 3 条"],"facts":["值得长期记住的新事实，最多 5 条"]}
规则：
- summary 用第三人称写，不要写成小鲸鱼的口吻。
- traits 必须是稳定、可复用的（例如“喜欢先看结论”“晚上效率高”），不要写一次性的情绪。
- 没有内容就返回空数组，不要硬编。
'@
  return @(
    @{ role = 'system'; content = $sys },
    @{ role = 'user'; content = ('日期：' + $Date + "`r`n对话：`r`n" + $TurnsText) }
  )
}

function Get-TurnsText {
  param($Turns, [int]$MaxChars = 6000)
  $sb = New-Object System.Text.StringBuilder
  foreach ($t in $Turns) {
    $who = if ($t.role -eq 'user') { '用户' } elseif ($t.role -eq 'assistant') { '小鲸鱼' } else { $t.role }
    [void]$sb.AppendLine($who + '：' + $t.content)
    if ($sb.Length -gt $MaxChars) { break }
  }
  $s = $sb.ToString()
  if ($s.Length -gt $MaxChars) { $s = $s.Substring(0, $MaxChars) }
  return $s
}

function ConvertFrom-LooseJson {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $t = $Text.Trim()
  # 去掉 ```json ... ``` 围栏
  if ($t -match '(?s)```(?:json)?\s*(.*?)```') { $t = $Matches[1].Trim() }
  $start = $t.IndexOf('{')
  $end = $t.LastIndexOf('}')
  if ($start -lt 0 -or $end -le $start) { return $null }
  $t = $t.Substring($start, $end - $start + 1)
  try { return ($t | ConvertFrom-Json) } catch { return $null }
}

Export-ModuleMember -Function Get-ToolDefinitions, Get-SystemPrompt, Get-ExtractionMessages, Get-ReflectionMessages, Get-TurnsText, ConvertFrom-LooseJson, Get-DayOfWeekName
