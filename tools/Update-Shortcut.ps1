param(
    [Parameter(Mandatory=$true)][string]$TargetRoot,
    [string]$DesktopPath = [Environment]::GetFolderPath('DesktopDirectory'),
    [string]$MarkerPath = (Join-Path $env:LOCALAPPDATA 'WbPetScript\shortcut.txt')
)
$ErrorActionPreference='Stop'
$target=[IO.Path]::GetFullPath($TargetRoot).TrimEnd('\')
$hostExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$hostArgs='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "'+(Join-Path $target 'app\Pet.ps1')+'" -Python "'+(Join-Path $target 'runtime\pythonw.exe')+'"'
$hostDir=Join-Path $target 'app'
$shell=New-Object -ComObject WScript.Shell
$rootLnk=Join-Path $DesktopPath 'WorkBuddy 桌宠（脚本版）.lnk'
function Read-Shortcut([string]$path) {
    # WSH uses the system code page for shortcut filenames on some Windows builds.
    # Let .NET handle the Unicode filename and give WSH an ASCII scratch name.
    $scratch=Join-Path ([IO.Path]::GetTempPath()) ('wb-link-'+[guid]::NewGuid().ToString('N')+'.lnk')
    try {
        [IO.File]::Copy($path,$scratch,$true)
        return $shell.CreateShortcut($scratch)
    } finally { if (Test-Path -LiteralPath $scratch) { [IO.File]::Delete($scratch) } }
}
function Is-Current([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    $link=Read-Shortcut $path
    return ($link.TargetPath -eq $hostExe -and $link.Arguments -eq $hostArgs -and $link.WorkingDirectory -eq $hostDir)
}
function Is-PetShortcut([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    try {
        $link=Read-Shortcut $path
        return ($link.TargetPath -eq $hostExe -and $link.Arguments -match '(?i)-File\s+"[^"\r\n]+[\\/]app[\\/]Pet\.ps1"')
    } catch { return $false }
}
function Find-Existing {
    if (Is-PetShortcut $rootLnk) { return $rootLnk }
    foreach ($item in @(Get-ChildItem -LiteralPath $DesktopPath -Filter 'WorkBuddy 桌宠*.lnk' -Recurse -Depth 3 -File -ErrorAction SilentlyContinue | Sort-Object FullName)) {
        if (Is-PetShortcut $item.FullName) { return $item.FullName }
    }
    return ''
}
$known=''; $knownTarget=''
if (Test-Path -LiteralPath $MarkerPath -PathType Leaf) {
    foreach ($line in [IO.File]::ReadAllLines($MarkerPath,[Text.Encoding]::UTF8)) {
        $line=$line.TrimStart([char]0xFEFF)
        if ($line.StartsWith('path=')) { $known=$line.Substring(5).Trim() }
        if ($line.StartsWith('target=')) { $knownTarget=$line.Substring(7).Trim() }
    }
}
$removed=$false
if ($known -and (Test-Path -LiteralPath $known -PathType Leaf) -and -not (Is-PetShortcut $known)) { return }
if ($known -and -not (Test-Path -LiteralPath $known -PathType Leaf)) {
    $known=Find-Existing
    if (-not $known) { $removed=$true }
}
if (-not $known -and -not $removed) {
    $known=Find-Existing
    if (-not $known) {
        # Never overwrite an unrelated shortcut, even if its display name matches ours.
        if (Test-Path -LiteralPath $rootLnk) { return }
        $known=$rootLnk
    }
}
if ($removed) { return } # Preserve the old marker as the user's deletion preference.
if ($knownTarget -ne $target -or -not (Is-Current $known)) {
    $scratch=Join-Path ([IO.Path]::GetTempPath()) ('wb-link-'+[guid]::NewGuid().ToString('N')+'.lnk')
    try {
        $link=$shell.CreateShortcut($scratch)
        $link.TargetPath=$hostExe; $link.Arguments=$hostArgs; $link.WorkingDirectory=$hostDir
        $link.IconLocation=(Join-Path $target 'app\Assets\pet.ico')+',0'
        $link.Save()
        [IO.File]::Copy($scratch,$known,$true)
    } finally { if (Test-Path -LiteralPath $scratch) { [IO.File]::Delete($scratch) } }
}
$content='path='+$known+"`r`n"+'target='+$target+"`r`n"
$old=''
if (Test-Path -LiteralPath $MarkerPath) { $old=[IO.File]::ReadAllText($MarkerPath,[Text.Encoding]::UTF8) }
if ($old -ne $content) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($MarkerPath))) | Out-Null
    [IO.File]::WriteAllText($MarkerPath,$content,[Text.UTF8Encoding]::new($true))
}
