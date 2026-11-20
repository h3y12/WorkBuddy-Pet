param([string]$TargetRoot, [switch]$PrepareOnly)
$ErrorActionPreference = 'Stop'
try {
    if (-not $TargetRoot) { $TargetRoot = Join-Path $env:LOCALAPPDATA 'Programs\WbPetScript\0.3.1' }
    $manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'MANIFEST.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $sourceRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    $target = [IO.Path]::GetFullPath($TargetRoot).TrimEnd('\') + '\'
    if ($target -eq $sourceRoot -or $target.StartsWith($sourceRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Choose an installation directory outside the extracted package.'
    }
    foreach ($entry in $manifest.files.PSObject.Properties) {
        $source = [IO.Path]::GetFullPath((Join-Path $sourceRoot $entry.Name))
        $destination = [IO.Path]::GetFullPath((Join-Path $target $entry.Name))
        if (-not $source.StartsWith($sourceRoot, [StringComparison]::OrdinalIgnoreCase) -or
            -not $destination.StartsWith($target, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid package path.' }
        if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $entry.Value) {
            throw ('Incomplete or modified package: ' + $entry.Name)
        }
        $copy = -not (Test-Path -LiteralPath $destination)
        if (-not $copy) { $copy = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $entry.Value }
        if ($copy) {
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
            # Copy content into a user directory. Do not copy the source ACL or SACL.
            [IO.File]::Copy($source, $destination, $true)
        }
    }
    [IO.File]::Copy((Join-Path $PSScriptRoot 'MANIFEST.json'), (Join-Path $target 'MANIFEST.json'), $true)
    $python = Join-Path $target 'runtime\pythonw.exe'
    if ($PrepareOnly) { Write-Output $target; return }
    # Shortcut targets the Windows host, not a newly built executable.
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'WorkBuddy 桌宠（脚本版）.lnk'))
        $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "' + (Join-Path $target 'app\Pet.ps1') + '" -Python "' + $python + '"'
        $shortcut.WorkingDirectory = Join-Path $target 'app'
        $shortcut.IconLocation = (Join-Path $target 'app\Assets\pet.ico') + ',0'
        $shortcut.Save()
    } catch { } # A blocked desktop directory does not prevent running the pet.
    & (Join-Path $target 'app\Pet.ps1') -Python $python
}
catch {
    $problem = '桌宠启动失败：' + $_.Exception.Message
    try { [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'startup-error.txt'), ($_ | Out-String)) } catch { }
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show($problem, 'WorkBuddy 桌宠（脚本版）') | Out-Null
    exit 1
}
