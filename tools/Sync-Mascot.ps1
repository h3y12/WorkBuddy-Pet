<#
.SYNOPSIS
    从本机 WorkBuddy 客户端提取官方吉祥物形象，写入桌宠的私有素材位。

.DESCRIPTION
    桌宠优先加载 app\Assets\mascot.local.png：这张图不进仓库、不进公开包，版权归腾讯。
    本脚本在目标电脑上就地运行，从该机已安装的 WorkBuddy 客户端里取这张 mascot 图，
    不需要联网，也不需要别人传图——每台机器都从自己合法安装的客户端里取自己的那一份。

    取到后会同步更新 MANIFEST.json 里该文件的 SHA256。这一步不能省：
    Launch.ps1 会逐个校验清单里的文件哈希，图片换了哈希不换，启动时会直接报
    "Incomplete or modified package" 并拒绝启动。

.PARAMETER RepoRoot
    仓库根目录。默认取本脚本所在目录的上一级。

.PARAMETER Source
    手动指定一张 PNG，跳过自动查找。用于本机没装 WorkBuddy、或想换成别的图的场景。

.PARAMETER DryRun
    只报告找到哪些候选，不写任何文件。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Sync-Mascot.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Sync-Mascot.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$InstallRoot,
    [string]$Source,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$script:TargetRelative = 'app/Assets/mascot.local.png'

function Write-Line {
    param([string]$Text)
    Write-Host ('  ' + $Text)
}

function ConvertFrom-BigEndian32 {
    param([byte[]]$Bytes, [int]$Offset)
    $v = [uint64]$Bytes[$Offset] * 16777216 + [uint64]$Bytes[$Offset + 1] * 65536 +
         [uint64]$Bytes[$Offset + 2] * 256 + [uint64]$Bytes[$Offset + 3]
    return [uint32]$v
}

function Get-PngSize {
    param([string]$Path)
    $stream = $null
    try {
        $stream = [IO.File]::OpenRead($Path)
        $buffer = New-Object byte[] 24
        $read = $stream.Read($buffer, 0, 24)
        if ($read -lt 24 -or $stream.Length -gt 32MB) { return $null }
        if ([BitConverter]::ToString($buffer,0,8) -ne '89-50-4E-47-0D-0A-1A-0A' -or
            [Text.Encoding]::ASCII.GetString($buffer,12,4) -ne 'IHDR') { return $null }
        $w = [long](ConvertFrom-BigEndian32 -Bytes $buffer -Offset 16)
        $h = [long](ConvertFrom-BigEndian32 -Bytes $buffer -Offset 20)
        if ($w -le 0 -or $h -le 0 -or $w*$h -gt 32000000) { return $null }
        Add-Type -AssemblyName System.Drawing
        $stream.Position=0
        $image=[Drawing.Image]::FromStream($stream,$false,$true)
        try {
            if ($image.Width -ne $w -or $image.Height -ne $h) { return $null }
            return [pscustomobject]@{ Width = $w; Height = $h }
        } finally { $image.Dispose() }
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

# WorkBuddy 可能装在任意盘、任意目录，按"运行中的进程 → 卸载注册表 → App Paths → 常见路径 → 各盘 Program Files"逐层找。
function Get-InstallRoots {
    $roots = New-Object System.Collections.Generic.List[string]

    foreach ($name in @('WorkBuddy', 'WorkBuddyX')) {
        foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            try {
                if ($process.Path) { $roots.Add((Split-Path -LiteralPath $process.Path)) }
            } catch { }
        }
    }

    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($key in $uninstallKeys) {
        foreach ($item in @(Get-ItemProperty -Path $key -ErrorAction SilentlyContinue)) {
            if ($item.DisplayName -notlike '*WorkBuddy*') { continue }
            if ($item.InstallLocation) { $roots.Add([string]$item.InstallLocation) }
            if ($item.DisplayIcon) {
                $exe = ([string]$item.DisplayIcon -replace ',\s*\d+$', '').Trim('"')
                if ($exe) { $roots.Add((Split-Path -LiteralPath $exe)) }
            }
        }
    }

    foreach ($key in @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\WorkBuddy.exe',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\WorkBuddy.exe')) {
        $item = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if ($item) {
            $exe = $item.'(default)'
            if ($exe) { $roots.Add((Split-Path -LiteralPath ([string]$exe).Trim('"'))) }
        }
    }

    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs'))) {
        if ($base) { $roots.Add((Join-Path $base 'WorkBuddy')) }
    }

    foreach ($drive in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if ($drive.Root -match '^[A-Za-z]:\\$') { $roots.Add((Join-Path $drive.Root 'Program Files\WorkBuddy')) }
    }

    $seen = @{}
    $valid = New-Object System.Collections.Generic.List[string]
    foreach ($root in $roots) {
        if (-not $root) { continue }
        $full = ([string]$root).TrimEnd('\')
        if (-not $full) { continue }
        $key = $full.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        if (Test-Path -LiteralPath (Join-Path $full 'resources')) { $valid.Add($full) }
    }
    return $valid
}

# 客户端把渲染资源打在 resources\app.asar 里，少数目录另有未打包副本。
# 未打包副本可直接复制；打包内的按 asar 头里的 offset 切片读出。
function Get-AsarEntries {
    param([string]$AsarPath)

    $stream = [IO.File]::OpenRead($AsarPath)
    try {
        $reader = New-Object IO.BinaryReader($stream)
        # 头部 16 字节：4 / 头部总长 / pickle 载荷长 / JSON 字符串长，JSON 正文从第 16 字节起。
        $sizePayload = $reader.ReadUInt32()
        $headerSize = [long]$reader.ReadUInt32()
        $payloadSize = [long]$reader.ReadUInt32()
        $jsonLength = [long]$reader.ReadUInt32()
        $base = 8L + $headerSize
        if ($sizePayload -ne 4 -or $jsonLength -gt 32MB -or $jsonLength -lt 2 -or
            $headerSize -lt 8 -or $base -gt $stream.Length -or $jsonLength -gt ($headerSize-8) -or
            $payloadSize -gt ($headerSize-4) -or $jsonLength -gt ($payloadSize-4)) { throw 'Invalid ASAR header.' }
        $bytes = $reader.ReadBytes($jsonLength)
        if ($bytes.Length -ne $jsonLength) { throw 'Truncated ASAR header.' }
        $header = [Text.UTF8Encoding]::new($false,$true).GetString($bytes) | ConvertFrom-Json
        if (-not $header.files) { throw 'ASAR files tree is missing.' }

        $entries = New-Object System.Collections.Generic.List[object]
        $length=$stream.Length
        $walk = {
            param($files,[string]$prefix)
            foreach ($property in $files.PSObject.Properties) {
                $name=$property.Name; $entry=$property.Value
                if ($name -in @('.','..') -or $name -match '[\\/]') { throw 'Invalid ASAR entry path.' }
                $relative=if ($prefix) { $prefix+'/'+$name } else { $name }
                if ($entry.files) { & $walk $entry.files $relative; continue }
                if ($name -notlike '*mascot*.png' -or $entry.link) { continue }
                $size=0L; $offset=0L
                if (-not [long]::TryParse([string]$entry.size,[ref]$size) -or $size -le 0 -or $size -gt 32MB) { continue }
                if ($entry.unpacked) {
                    $entries.Add([pscustomobject]@{Relative=$relative;Size=$size;Unpacked=$true;AsarPath=$AsarPath})
                    continue
                }
                if (-not [long]::TryParse([string]$entry.offset,[ref]$offset) -or $offset -lt 0 -or
                    $offset -gt ($length-$base) -or $size -gt ($length-$base-$offset)) { throw ('Invalid ASAR range: '+$relative) }
                $entries.Add([pscustomobject]@{Relative=$relative;Size=$size;Offset=$offset;Base=$base;Unpacked=$false;AsarPath=$AsarPath})
            }
        }
        & $walk $header.files ''
        return $entries
    } finally {
        $stream.Dispose()
    }
}

function Export-AsarEntry {
    param($Entry, [string]$Destination)
    $stream = [IO.File]::OpenRead($Entry.AsarPath)
    try {
        $stream.Position = $Entry.Base + $Entry.Offset
        $buffer = New-Object byte[] 65536
        $output = [IO.File]::Create($Destination)
        try {
            $remaining = $Entry.Size
            while ($remaining -gt 0) {
                $want = [int][Math]::Min($remaining, $buffer.Length)
                $got = $stream.Read($buffer, 0, $want)
                if ($got -le 0) { throw ('读取 app.asar 时提前结束：' + $Entry.Relative) }
                $output.Write($buffer, 0, $got)
                $remaining -= $got
            }
        } finally {
            $output.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Get-MascotCandidates {
    param([string]$InstallRoot)

    $candidates = New-Object System.Collections.Generic.List[object]

    $unpackedGlobs = @(
        'resources\app.asar.unpacked\resources\extensions\*\ui\assets\mascot*.png',
        'resources\app.asar.unpacked\resources\*\mascot*.png'
    )
    foreach ($glob in $unpackedGlobs) {
        $pattern = Join-Path $InstallRoot $glob
        foreach ($file in @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue)) {
            $candidates.Add([pscustomobject]@{
                Kind        = 'file'
                Label       = $file.Name
                Origin      = 'app.asar.unpacked'
                Path        = $file.FullName
                Relative    = $file.Name
            })
        }
    }

    $asarPath = Join-Path $InstallRoot 'resources\app.asar'
    if (Test-Path -LiteralPath $asarPath) {
        foreach ($entry in @(Get-AsarEntries -AsarPath $asarPath)) {
            if ($entry.Unpacked) {
                $path=Join-Path ($asarPath+'.unpacked') ($entry.Relative -replace '/', '\')
                if (Test-Path -LiteralPath $path -PathType Leaf) {
                    $candidates.Add([pscustomobject]@{Kind='file';Label=[IO.Path]::GetFileName($entry.Relative);Origin='app.asar.unpacked';Path=$path;Relative=$entry.Relative})
                }
                continue
            }
            $candidates.Add([pscustomobject]@{
                Kind     = 'asar'
                Label    = [IO.Path]::GetFileName($entry.Relative)
                Origin   = 'app.asar'
                Path     = $null
                Relative = $entry.Relative
                Entry    = $entry
            })
        }
    }
    return $candidates
}

function Resolve-Candidate {
    param($Candidate, [string]$ScratchDir)
    if ($Candidate.Kind -eq 'file') { return $Candidate.Path }
    $name = [IO.Path]::GetFileNameWithoutExtension($Candidate.Label)
    $target = Join-Path $ScratchDir ($name + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.png')
    Export-AsarEntry -Entry $Candidate.Entry -Destination $target
    return $target
}

function Get-FileSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Update-Manifest {
    param([string]$ManifestPath, [string]$Relative, [string]$Hash)

    $manifest=[IO.File]::ReadAllText($ManifestPath,[Text.Encoding]::UTF8) | ConvertFrom-Json
    if (-not $manifest.files -or $manifest.files -isnot [pscustomobject]) { throw 'Invalid manifest files object.' }
    $manifest.files | Add-Member -NotePropertyName $Relative -NotePropertyValue $Hash -Force
    $temporary=$ManifestPath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    $backup=$temporary+'.bak'
    try {
        [IO.File]::WriteAllText($temporary,($manifest | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
        [IO.File]::Replace($temporary,$ManifestPath,$backup,$true)
    } finally {
        foreach ($path in @($temporary,$backup)) { if (Test-Path -LiteralPath $path) { [IO.File]::Delete($path) } }
    }
    return '已更新'
}

# ---------------------------------------------------------------- 主流程

if (-not $RepoRoot) {
    if ($PSScriptRoot) { $RepoRoot = Split-Path -LiteralPath $PSScriptRoot }
    else { $RepoRoot = (Get-Location).Path }
}
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)

Write-Host ''
Write-Host 'WorkBuddy 桌宠 · 官方形象同步'
Write-Host ''

$targetPath = Join-Path $RepoRoot ($script:TargetRelative -replace '/', '\')
$manifestPath = Join-Path $RepoRoot 'MANIFEST.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw ('找不到 MANIFEST.json，仓库根目录不对：' + $RepoRoot) }

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('WbPet-mascot-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null

try {
    $resolved = New-Object System.Collections.Generic.List[object]

    if ($Source) {
        $sourcePath = [IO.Path]::GetFullPath($Source)
        if (-not (Test-Path -LiteralPath $sourcePath)) { throw ('指定的图片不存在：' + $sourcePath) }
        if (-not (Get-PngSize -Path $sourcePath)) { throw '指定文件不是可解码的 PNG 图片。' }
        $resolved.Add([pscustomobject]@{ Path = $sourcePath; Label = [IO.Path]::GetFileName($sourcePath); Origin = '手动指定' })
        Write-Line ('指定来源：' + $sourcePath)
    } else {
        if ($InstallRoot) {
            $explicit = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
            if (-not (Test-Path -LiteralPath (Join-Path $explicit 'resources'))) {
                throw ('指定的安装目录里没有 resources：' + $explicit)
            }
            $roots = @($explicit)
        } else {
            $roots = @(Get-InstallRoots)
        }
        if ($roots.Count -eq 0) {
            throw '没找到 WorkBuddy 安装目录。确认本机已安装客户端；或用 -InstallRoot / -Source 指定。'
        }
        foreach ($root in $roots) {
            $candidates = @(Get-MascotCandidates -InstallRoot $root)
            if ($candidates.Count -eq 0) { continue }
            Write-Line ('安装目录：' + $root)
            foreach ($candidate in $candidates) {
                try {
                    $path = Resolve-Candidate -Candidate $candidate -ScratchDir $scratch
                    $size = Get-PngSize -Path $path
                    if (-not $size) { continue }
                    $resolved.Add([pscustomobject]@{
                        Path   = $path
                        Label  = $candidate.Label
                        Origin = $candidate.Origin
                        Width  = $size.Width
                        Height = $size.Height
                    })
                } catch {
                    Write-Line ('跳过 ' + $candidate.Label + '：' + $_.Exception.Message)
                }
            }
            if ($resolved.Count -gt 0) { break }
        }
        if ($resolved.Count -eq 0) {
            throw '在 WorkBuddy 安装目录里没找到 mascot 图片。客户端版本可能改过资源布局；可用 -Source 指定一张 PNG。'
        }
    }

    # 优先 mascot-new（当前版本），其次未打包副本（省一次 asar 切片），最后按像素面积取最大的。
    $best = $resolved |
        Sort-Object -Property @{ Expression = { if ($_.Label -like 'mascot-new*') { 0 } else { 1 } } },
                              @{ Expression = { if ($_.Origin -eq 'app.asar.unpacked') { 0 } else { 1 } } },
                              @{ Expression = { if ($_.PSObject.Properties['Width']) { $_.Width * $_.Height } else { 0 } }; Descending = $true } |
        Select-Object -First 1

    foreach ($item in $resolved) {
        if ($item -eq $best) { continue }
        if ($item.PSObject.Properties['Width']) {
            Write-Line ('候选：' + $item.Label + '（' + $item.Width + '×' + $item.Height + '，' + $item.Origin + '）')
        }
    }
    if ($best.PSObject.Properties['Width']) {
        Write-Line ('选用：' + $best.Label + '（' + $best.Width + '×' + $best.Height + '，' + $best.Origin + '）')
    }

    $hash = Get-FileSha256 -Path $best.Path
    Write-Line ('SHA256：' + $hash)

    if ($DryRun) {
        Write-Line 'DryRun：不写任何文件。'
        Write-Host ''
        return
    }

    # Validate the manifest before changing any artwork, including minified JSON manifests.
    $existingManifest=[IO.File]::ReadAllText($manifestPath,[Text.Encoding]::UTF8) | ConvertFrom-Json
    if (-not $existingManifest.files -or $existingManifest.files -isnot [pscustomobject]) { throw 'Invalid manifest files object.' }
    $hadTarget=Test-Path -LiteralPath $targetPath -PathType Leaf
    if ($hadTarget) {
        $backupDir = Join-Path $env:LOCALAPPDATA 'WbPetScript\mascot-backup'
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
        $backup = Join-Path $backupDir ($stamp + '-mascot.local.png')
        Copy-Item -LiteralPath $targetPath -Destination $backup -Force
        Write-Line ('旧图备份：' + $backup)
    }

    $targetDir = Split-Path -LiteralPath $targetPath
    if (-not (Test-Path -LiteralPath $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
    $temporary=$targetPath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    $rollback=$temporary+'.bak'
    try {
        [IO.File]::Copy($best.Path,$temporary,$true)
        if ($hadTarget) { [IO.File]::Replace($temporary,$targetPath,$rollback,$true) }
        else { [IO.File]::Move($temporary,$targetPath) }
        try { $action = Update-Manifest -ManifestPath $manifestPath -Relative $script:TargetRelative -Hash $hash }
        catch {
            if ($hadTarget) { [IO.File]::Copy($rollback,$targetPath,$true) }
            else { [IO.File]::Delete($targetPath) }
            throw
        }
    } finally {
        foreach ($path in @($temporary,$rollback)) { if (Test-Path -LiteralPath $path) { [IO.File]::Delete($path) } }
    }
    Write-Line ('已写入：' + $targetPath)
    Write-Line ('MANIFEST.json：' + $action + ' ' + $script:TargetRelative)

    Write-Host ''
    Write-Host '下一步'
    Write-Line '1. 从托盘退出正在运行的桌宠。'
    Write-Line '2. 双击 Start.vbs（或 Start.cmd）重新部署，会按新哈希把图铺到 LocalAppData。'
    Write-Host ''
} finally {
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    $scratchFull=[IO.Path]::GetFullPath($scratch)
    if ($scratchFull.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($scratchFull) -like 'WbPet-mascot-*' -and (Test-Path -LiteralPath $scratchFull)) {
        Remove-Item -LiteralPath $scratchFull -Recurse -Force -ErrorAction SilentlyContinue
    }
}
