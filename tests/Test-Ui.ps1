$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('wb-script-ui-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temporary) | Out-Null
& (Join-Path $root 'app\Pet.ps1') -Smoke -ConfigPath (Join-Path $temporary 'config.json') -DataRoot $temporary -Snapshot (Join-Path $temporary 'preview.png')
if (-not (Test-Path (Join-Path $temporary 'preview.png'))) { throw 'UI snapshot was not created.' }
Write-Output ('Test artifacts: '+$temporary)
