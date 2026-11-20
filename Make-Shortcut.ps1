param([string]$AppRoot)
$ErrorActionPreference = 'Stop'
if (-not $AppRoot) { $AppRoot = $PSScriptRoot }

# 原地启动：不复制到 LocalAppData，直接指向解压目录里的 Pet.ps1 与随包解释器
$pet = Join-Path $AppRoot 'app\Pet.ps1'
$python = Join-Path $AppRoot 'runtime\pythonw.exe'
foreach ($p in @($pet, $python)) {
    if (-not (Test-Path -LiteralPath $p)) { throw ('missing: ' + $p) }
}

$lnk = Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'WorkBuddy 桌宠（脚本版）.lnk'
$shell = New-Object -ComObject WScript.Shell
$sc = $shell.CreateShortcut($lnk)
$sc.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$sc.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "' + $pet + '" -Python "' + $python + '"'
$sc.WorkingDirectory = Join-Path $AppRoot 'app'
$sc.IconLocation = (Join-Path $AppRoot 'app\Assets\pet.ico') + ',0'
$sc.Description = 'WorkBuddy 桌宠（脚本版，原地运行）'
$sc.Save()
Write-Output $lnk
