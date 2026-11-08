# ============================================================================
#  Router.psm1 — 指令路由器
#  输入一句话，判断由谁执行：本地动作 / 浏览器 / DSH / 聊天 / 需要确认
# ============================================================================
function Resolve-Intent {
  param(
    [string]$Text,
    [string[]]$KnownNames = @()
  )
  $t = ($Text -replace '\s+', ' ').Trim()
  if ([string]::IsNullOrWhiteSpace($t)) {
    return [pscustomobject]@{ kind = 'chat'; reason = '空输入' }
  }

  if ($t -match '^(?:@dsh|dsh:|交给\s*dsh|让\s*dsh)\s*[:：]?\s*(.+)$') {
    return [pscustomobject]@{ kind = 'dsh'; task = $Matches[1].Trim(); reason = '显式 @dsh' }
  }

  $url = ''
  if ($t -match '(https?://[^\s，。]+)') { $url = $Matches[1] }
  if ($url -and ($t -match '(读|看看|看一下|总结|分析|讲什么|讲了什么|内容)')) {
    return [pscustomobject]@{ kind = 'browser_read'; url = $url; reason = '读网页' }
  }

  if ($t -match '(搜一下|搜索一下|搜索|查一下|查查|网上查|搜搜看)\s*(.+)') {
    $q = $Matches[2].Trim()
    if ($t -match '(总结|念|告诉|说给|前几|是什么|怎么样|介绍|讲讲|对比|区别|资料|信息)') {
      return [pscustomobject]@{ kind = 'browser_search'; query = $q; reason = '搜索并总结' }
    }
    return [pscustomobject]@{ kind = 'action_search'; query = $q; reason = '搜索并打开浏览器' }
  }

  if ($t -match '^(?:请|帮我|麻烦你?|给我)?\s*(?:打开|启动|开启|开一下|开个)\s*(.+)$') {
    $name = $Matches[1].Trim()
    if ($KnownNames.Count -eq 0) {
      return [pscustomobject]@{ kind = 'action_open'; name = $name; reason = '打开动作（无白名单）' }
    }
    foreach ($k in $KnownNames) {
      if ($name.ToLower().Contains(([string]$k).ToLower())) {
        return [pscustomobject]@{ kind = 'action_open'; name = $name; reason = ('白名单：' + $k) }
      }
    }
    return [pscustomobject]@{ kind = 'chat'; reason = '未知应用，交模型判断' }
  }

  $workVerb = $t -match '(建|创建|新建|删除|删掉|修改|改成|重命名|移动|复制|写入|写|生成|跑|运行|执行|安装|部署|修复|重构|整理|清理|分析|抓取|爬)'
  $workObj = ($t -match '(文件|报告|html|脚本|代码|项目|仓库|文件夹|目录|下载|桌面|文档|工作区|测试|表格|excel|word|pdf|数据|依赖)') -or ($t -match '\.[A-Za-z0-9]{2,5}\b')
  if ($workVerb -and $workObj) {
    if ($t -match '(可以吗|能不能|要不要|好吗|行吗|是否|该不该)') {
      return [pscustomobject]@{ kind = 'ambiguous'; task = $t; reason = '工作请求 + 疑问' }
    }
    return [pscustomobject]@{ kind = 'dsh'; task = $t; reason = '文件/命令类工作' }
  }

  return [pscustomobject]@{ kind = 'chat'; reason = '闲聊/问答' }
}

Export-ModuleMember -Function Resolve-Intent
