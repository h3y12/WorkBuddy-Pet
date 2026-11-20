$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('wb-tools-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temporary) | Out-Null
$desktop=Join-Path $temporary 'desktop'
[IO.Directory]::CreateDirectory($desktop) | Out-Null
$marker=Join-Path $temporary 'marker.txt'
$target=Join-Path $temporary 'v1'
$updater=Join-Path $root 'tools\Update-Shortcut.ps1'
$sync=Join-Path $root 'tools\Sync-Mascot.ps1'
$shell=New-Object -ComObject WScript.Shell
function Assert($condition,$message) { if (-not $condition) { throw $message } }
function Update { & $updater -TargetRoot $target -DesktopPath $desktop -MarkerPath $marker }
Update
$link=@(Get-ChildItem -LiteralPath $desktop -Filter '*.lnk')[0].FullName
$stamp=[IO.File]::GetLastWriteTimeUtc($link)
Update
Assert ([IO.File]::GetLastWriteTimeUtc($link) -eq $stamp) 'Repeated launch rewrote shortcut'
$folder=Join-Path $desktop 'moved'
[IO.Directory]::CreateDirectory($folder) | Out-Null
$moved=Join-Path $folder ([IO.Path]::GetFileName($link))
[IO.File]::Move($link,$moved)
$target=Join-Path $temporary 'v2'
Update
Assert (-not (Test-Path -LiteralPath $link)) 'Moved shortcut duplicated'
Assert ($shell.CreateShortcut($moved).Arguments.Contains($target)) 'Moved shortcut did not upgrade'
[IO.File]::Delete($moved)
Update
$target=Join-Path $temporary 'v3'
Update
Assert (-not (Test-Path -LiteralPath $link)) 'Deleted shortcut resurrected'
[IO.File]::Delete($marker)
$other=$shell.CreateShortcut($link)
$other.TargetPath=Join-Path $env:SystemRoot 'notepad.exe'; $other.Save()
Update
Assert ($shell.CreateShortcut($link).TargetPath -eq $other.TargetPath) 'Unrelated shortcut overwritten'
[IO.File]::WriteAllText($marker,('path='+$link+"`r`n"+'target='+$target))
Update
Assert ($shell.CreateShortcut($link).TargetPath -eq $other.TargetPath) 'Replaced marked shortcut overwritten'
Write-Output 'Shortcut checks passed'

$repo=Join-Path $temporary 'repo'
$assets=Join-Path $repo 'app\Assets'
[IO.Directory]::CreateDirectory($assets) | Out-Null
$manifest=Join-Path $repo 'MANIFEST.json'
[IO.File]::WriteAllText($manifest,'{"version":"test","files":{}}')
$source=Join-Path $root 'app\Assets\mascot.png'
$image=Join-Path $assets 'mascot.local.png'
$original=[IO.File]::ReadAllText($manifest)
& $sync -RepoRoot $repo -Source $source -DryRun
Assert (-not (Test-Path -LiteralPath $image)) 'Dry run wrote artwork'
Assert ([IO.File]::ReadAllText($manifest) -eq $original) 'Dry run wrote manifest'
& $sync -RepoRoot $repo -Source $source
$data=Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
$hash=(Get-FileHash -LiteralPath $image).Hash
Assert ($data.files.'app/Assets/mascot.local.png' -eq $hash) 'Minified manifest hash mismatch'
$bad=Join-Path $temporary 'bad.png'
[IO.File]::WriteAllBytes($bad,[IO.File]::ReadAllBytes($source)[0..23])
$failed=$false
try { & $sync -RepoRoot $repo -Source $bad } catch { $failed=$true }
Assert $failed 'Truncated PNG accepted'
Assert ((Get-FileHash -LiteralPath $image).Hash -eq $hash) 'Bad PNG replaced artwork'
$lock=[IO.File]::Open($manifest,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
$oldLocal=$env:LOCALAPPDATA
$replacement=Join-Path $temporary 'replacement.png'
Add-Type -AssemblyName System.Drawing
$bitmap=[Drawing.Bitmap]::new(2,2)
try { $bitmap.Save($replacement,[Drawing.Imaging.ImageFormat]::Png) } finally { $bitmap.Dispose() }
try {
    $env:LOCALAPPDATA=$temporary
    $failed=$false
    try { & $sync -RepoRoot $repo -Source $replacement } catch { $failed=$true }
    Assert $failed 'Locked manifest unexpectedly replaced'
    Assert ((Get-FileHash -LiteralPath $image).Hash -eq $hash) 'Manifest failure did not restore artwork'
} finally { $lock.Dispose(); $env:LOCALAPPDATA=$oldLocal }
Write-Output 'Artwork checks passed'

$install=Join-Path $temporary 'install'
$resources=Join-Path $install 'resources'
[IO.Directory]::CreateDirectory($resources) | Out-Null
$png=[IO.File]::ReadAllBytes($source)
$tree=@{files=@{nested=@{files=@{
    'mascot-old.png'=@{size=$png.Length;unpacked=$true}
    'mascot-new.png'=@{size=$png.Length;integrity=@{hash=('a'*600)};offset='0'}
}}}}
$json=[Text.Encoding]::UTF8.GetBytes(($tree | ConvertTo-Json -Depth 10 -Compress))
$padding=(4-($json.Length % 4)) % 4
$asar=Join-Path $resources 'app.asar'
$stream=[IO.File]::Create($asar)
$writer=[IO.BinaryWriter]::new($stream)
try {
    $writer.Write([uint32]4); $writer.Write([uint32](8+$json.Length+$padding))
    $writer.Write([uint32](4+$json.Length+$padding)); $writer.Write([uint32]$json.Length)
    $writer.Write($json); $writer.Write((New-Object byte[] $padding)); $writer.Write($png)
} finally { $writer.Dispose() }
$oldLocal=$env:LOCALAPPDATA
try {
    $env:LOCALAPPDATA=$temporary
    & $sync -RepoRoot $repo -InstallRoot $install
    Assert ((Get-FileHash -LiteralPath $image).Hash -eq $hash) 'ASAR nested extraction mismatch'
    $stream=[IO.File]::OpenWrite($asar)
    try { $stream.SetLength($stream.Length-1) } finally { $stream.Dispose() }
    $failed=$false
    try { & $sync -RepoRoot $repo -InstallRoot $install } catch { $failed=$true }
    Assert $failed 'Out-of-bounds ASAR accepted'
} finally { $env:LOCALAPPDATA=$oldLocal }
Write-Output 'ASAR checks passed'
Write-Output ('Test artifacts: '+$temporary)
