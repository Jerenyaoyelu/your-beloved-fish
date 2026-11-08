# ============================================================================
#  Skins.psm1 — 小鲸鱼皮肤（形象）管理
#  · data/skins/      用户导入的图片（png / gif / jpg）
#  · data/skins.json  皮肤清单 + 当前使用的皮肤
#  · 默认皮肤 = assets/whale.png
# ============================================================================

$script:DataDir = $null
$script:SkinsDir = $null
$script:IndexPath = $null
$script:DefaultImage = $null
$script:Skins = $null

function New-DefaultSkinsIndex {
  return [pscustomobject]@{
    version = 1
    active  = 'default'
    skins   = @([pscustomobject]@{ id = 'default'; name = '默认小鲸鱼'; file = ''; builtin = $true })
  }
}

function Initialize-Skins {
  param(
    [Parameter(Mandatory)][string]$DataDir,
    [Parameter(Mandatory)][string]$DefaultImage
  )
  $script:DataDir = $DataDir
  $script:SkinsDir = Join-Path $DataDir 'skins'
  $script:IndexPath = Join-Path $DataDir 'skins.json'
  $script:DefaultImage = $DefaultImage
  if (-not (Test-Path $script:SkinsDir)) { New-Item -ItemType Directory -Path $script:SkinsDir -Force | Out-Null }

  $script:Skins = $null
  if (Test-Path $script:IndexPath) {
    try {
      $raw = Get-Content -LiteralPath $script:IndexPath -Raw -Encoding UTF8
      if ($raw -and $raw.Trim()) { $script:Skins = $raw | ConvertFrom-Json }
    } catch { $script:Skins = $null }
  }
  if (-not $script:Skins) { $script:Skins = New-DefaultSkinsIndex }
  $script:Skins.skins = @($script:Skins.skins)

  if (-not (@($script:Skins.skins) | Where-Object { $_.id -eq 'default' })) {
    $script:Skins.skins = @([pscustomobject]@{ id = 'default'; name = '默认小鲸鱼'; file = ''; builtin = $true }) + @($script:Skins.skins)
  }
  if (-not $script:Skins.active -or -not (Get-SkinById $script:Skins.active)) { $script:Skins.active = 'default' }
  Save-Skins
}

function Save-Skins {
  try {
    $tmp = $script:IndexPath + '.tmp'
    $script:Skins | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $script:IndexPath -Force
  } catch { }
}

function Get-Skins { return @($script:Skins.skins) }

function Get-SkinById([string]$Id) {
  foreach ($s in @($script:Skins.skins)) { if ($s.id -eq $Id) { return $s } }
  return $null
}

function Get-ActiveSkinId {
  if (-not $script:Skins.active) { return 'default' }
  return [string]$script:Skins.active
}

function Set-ActiveSkinId([string]$Id) {
  if (-not (Get-SkinById $Id)) { $Id = 'default' }
  $script:Skins.active = $Id
  Save-Skins
}

function Get-SkinPath([string]$Id) {
  $s = Get-SkinById $Id
  if (-not $s -or -not $s.file) { return $script:DefaultImage }
  $p = Join-Path $script:DataDir $s.file
  if (Test-Path $p) { return $p }
  return $script:DefaultImage
}

function Get-ActiveSkinPath {
  return (Get-SkinPath (Get-ActiveSkinId))
}

function Add-Skin([string]$SourcePath, [string]$Name = '') {
  if (-not (Test-Path $SourcePath)) { throw '找不到这个文件' }
  $ext = [System.IO.Path]::GetExtension($SourcePath).ToLowerInvariant()
  if (@('.png', '.gif', '.jpg', '.jpeg') -notcontains $ext) { throw '只支持 png / gif / jpg' }
  if (-not $Name) { $Name = [System.IO.Path]::GetFileNameWithoutExtension($SourcePath) }
  $Name = ($Name -replace '\s+', ' ').Trim()
  if ($Name.Length -gt 24) { $Name = $Name.Substring(0, 24) }

  $id = 's' + [guid]::NewGuid().ToString('N').Substring(0, 10)
  $fileName = $id + $ext
  $dest = Join-Path $script:SkinsDir $fileName
  Copy-Item -LiteralPath $SourcePath -Destination $dest -Force
  $rec = [pscustomobject]@{
    id      = $id
    name    = $Name
    file    = ('skins/' + $fileName)
    builtin = $false
    created = (Get-Date).ToString('s')
  }
  $script:Skins.skins = @($script:Skins.skins) + $rec
  Save-Skins
  return $rec
}

function Remove-Skin([string]$Id) {
  if ($Id -eq 'default') { return $false }
  $s = Get-SkinById $Id
  if (-not $s) { return $false }
  if ($s.file) {
    $p = Join-Path $script:DataDir $s.file
    if (Test-Path $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
  }
  $script:Skins.skins = @($script:Skins.skins | Where-Object { $_.id -ne $Id })
  if ($script:Skins.active -eq $Id) { $script:Skins.active = 'default' }
  Save-Skins
  return $true
}

Export-ModuleMember -Function Initialize-Skins, Get-Skins, Get-SkinById, Get-ActiveSkinId, Set-ActiveSkinId, Get-SkinPath, Get-ActiveSkinPath, Add-Skin, Remove-Skin
