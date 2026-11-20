param(
    [string]$Python,
    [string]$DataRoot,
    [string]$ConfigPath,
    [string]$Snapshot,
    [switch]$Smoke,
    [switch]$Stay
)
$ErrorActionPreference = 'Stop'
$script:canWriteTestConfig = $PSBoundParameters.ContainsKey('ConfigPath')
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
$script:version = '0.3.1-script'
if (-not $Python) { $Python = Join-Path (Split-Path $PSScriptRoot -Parent) 'runtime\pythonw.exe' }
if (-not $DataRoot) { $DataRoot = Join-Path $env:LOCALAPPDATA 'WbPet' }
if (-not $ConfigPath) { $ConfigPath = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'WbPet\config.json' }
$script:dataRoot = $DataRoot
$script:configPath = $ConfigPath
$script:statePath = Join-Path $DataRoot 'state.json'
$script:worker = $null
$script:tray = $null
$script:settings = $null
$script:timer = $null
$script:mutex = $null
$script:ui = @{}
$script:cfg = [ordered]@{Left=0.0;Top=0.0;HasPosition=$false;PetScale=1.0;FontSize=11.0;PanelOpacity=95.0;Topmost=$true;ShowPanel=$true;LaunchWorkBuddy=$true}
$script:lastSeq = $null
$script:lastPending = 0
$script:doneUntil = [DateTime]::MinValue
$script:lastProcessCheck = [DateTime]::MinValue
$script:lastWorkerAttempt = [DateTime]::MinValue
$script:hasSeenWorkBuddy = $false
$script:misses = 0
$script:kind = 'offline'
$script:lastError = ''
$script:graceUntil = [DateTime]::Now.AddMinutes(2)

function Field($object, [string]$name, $default = $null) {
    if ($null -eq $object) { return $default }
    $property = $object.PSObject.Properties[$name]
    if ($null -eq $property -or $null -eq $property.Value) { return $default }
    return $property.Value
}
function Save-Configuration {
    try {
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($script:configPath)) | Out-Null
        $temporary = $script:configPath + '.script.tmp'
        [IO.File]::WriteAllText($temporary, ($script:cfg | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $script:configPath) {
            [IO.File]::Replace($temporary, $script:configPath, ($script:configPath+'.previous.json'), $true)
        } else { [IO.File]::Move($temporary, $script:configPath) }
    } catch {
        $problem='设置保存失败：' + $_.Exception.Message
        if ($script:lastError -ne $problem) { Notify '桌宠设置未保存' $problem }
        $script:lastError=$problem
    }
}
function Stop-Animation {
    $script:ui.BodyShift.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $null)
    foreach ($name in @('Dot1','Dot2','Dot3')) {
        $script:ui[$name].BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    }
}
function Apply-Animation {
    Stop-Animation
    if (-not $script:window.IsVisible -or -not [System.Windows.SystemParameters]::ClientAreaAnimation) { return }
    $motion = [System.Windows.Media.Animation.DoubleAnimation]::new(-2.0, 1.5, [System.Windows.Duration]::new([TimeSpan]::FromSeconds(1.8)))
    $motion.AutoReverse = $true
    $motion.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($motion, 20)
    $script:ui.BodyShift.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $motion)
    if ($script:kind -eq 'working') {
        $i = 0
        foreach ($name in @('Dot1','Dot2','Dot3')) {
            $fade = [System.Windows.Media.Animation.DoubleAnimation]::new(0.25, 1.0, [System.Windows.Duration]::new([TimeSpan]::FromSeconds(0.5)))
            $fade.AutoReverse=$true; $fade.RepeatBehavior=[System.Windows.Media.Animation.RepeatBehavior]::Forever
            $fade.BeginTime=[TimeSpan]::FromSeconds(0.15*$i)
            [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($fade, 20)
            $script:ui[$name].BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
            $i++
        }
    }
}
function Apply-Configuration {
    $factor = [Math]::Max(10.0,[Math]::Min(18.0,[double]$script:cfg.FontSize))/11.0
    $script:ui.StatusText.FontSize=12.5*$factor
    $script:ui.ExtraText.FontSize=10.5*$factor
    $script:ui.TitleText.FontSize=11*$factor
    $script:ui.TitleText.MaxWidth=220*$factor
    $script:ui.UsageText.FontSize=10.5*$factor
    $script:ui.Bubble.Opacity=[Math]::Max(0.2,[Math]::Min(1.0,[double]$script:cfg.PanelOpacity/100.0))
    $scale=[Math]::Max(0.4,[Math]::Min(1.0,[double]$script:cfg.PetScale))
    $script:ui.PetScale.ScaleX=$scale; $script:ui.PetScale.ScaleY=$scale
    $script:window.Topmost=[bool]$script:cfg.Topmost
    $script:ui.MenuTopmost.IsChecked=$script:cfg.Topmost
    $script:ui.MenuLaunchWb.IsChecked=$script:cfg.LaunchWorkBuddy
    if ($script:cfg.ShowPanel) { $script:ui.Bubble.Visibility='Visible'; $script:ui.MenuTogglePanel.Header='收起状态面板' }
    else { $script:ui.Bubble.Visibility='Collapsed'; $script:ui.MenuTogglePanel.Header='展开状态面板' }
    if ($script:settings) {
        $script:settings.FindName('FontLabel').Text='字号：'+$script:cfg.FontSize
        $script:settings.FindName('OpacityLabel').Text='面板不透明度：'+$script:cfg.PanelOpacity+'%'
        $script:settings.FindName('PetLabel').Text='角色大小：'+[int]($script:cfg.PetScale*100)+'%'
    }
}
function Notify([string]$title, [string]$text) {
    if ($script:tray) {
        try { $script:tray.ShowBalloonTip(3000,$title,$text,[System.Windows.Forms.ToolTipIcon]::Info) } catch { }
    }
}
function Show-State([string]$kind,[string]$label,[string]$title,[string]$usage,[double]$ratio=0,[string]$badge='') {
    $colors=@{working='#2F6FEB';done='#1B8A53';unread='#CC861C';confirm='#CC861C';error='#C64747';idle='#7D838C';offline='#7D838C'}
    $color=$colors[$kind]
    $brush=[System.Windows.Media.BrushConverter]::new().ConvertFromString($color)
    $script:ui.StatusText.Text=$label
    $script:ui.StatusText.Foreground=$brush
    $script:ui.StatusDot.Fill=$brush
    $script:ui.TitleText.Text=$title
    $script:ui.TitleText.ToolTip=$title
    $script:ui.UsageText.Text=$usage
    $script:ui.UsageText.Visibility= $(if ($usage) {'Visible'} else {'Collapsed'})
    $script:ui.ExtraText.Text=''
    # Integer bounds select Math's integer overload in PowerShell 5.1 and round fractions to 0/1.
    $ratio=[Math]::Max(0.0,[Math]::Min(1.0,$ratio))
    $script:ui.UsageCol.Width=[System.Windows.GridLength]::new($ratio,[System.Windows.GridUnitType]::Star)
    $script:ui.RestCol.Width=[System.Windows.GridLength]::new(1-$ratio,[System.Windows.GridUnitType]::Star)
    $script:ui.Badge.Visibility= $(if ($badge) {'Visible'} else {'Collapsed'})
    $script:ui.BadgeText.Text=$badge
    $script:ui.BadgeCircle.Fill=$brush
    $script:ui.Dots.Visibility= $(if ($kind -eq 'working') {'Visible'} else {'Collapsed'})
    if ($script:kind -ne $kind) { $script:kind=$kind; Apply-Animation }
}
function Apply-State($state) {
    $now=[DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    $ts=[double](Field $state 'ts' 0)
    if ($ts -gt ($now+30000) -or $now-$ts -gt 10000 -or (Field $state 'stale' $false) -or (Field $state 'error' '') -or -not (Field $state 'db_ok' $true)) {
        $script:doneUntil=[DateTime]::MinValue
        Show-State 'offline' '读数暂时中断' ('等待恢复：'+(Field $state 'error' '数据超过 10 秒未更新')) ''
        return
    }
    if (-not (Field $state 'app_running' $false)) {
        $script:doneUntil=[DateTime]::MinValue
        Show-State 'offline' '等待 WorkBuddy' '请打开 WorkBuddy，或在右键菜单启用自动启动' ''
        return
    }
    $active=Field $state 'active'
    $status=Field $active 'status' 'idle'
    $title=Field $active 'title' '暂无任务'
    $usage=Field $state 'usage'
    $size=[double](Field $usage 'session_size' 0)
    $ratio=0.0
    if ($size -gt 0) { $ratio=[double](Field $usage 'session_used' 0)/$size }
    $usageText=('上下文 {0:0.0}%  ·  已观测使用 {1:0.##} 积分' -f (100*$ratio),[double](Field $usage 'credits_today' 0))
    $event=Field $state 'event'
    if ($null -ne $event) {
        $seq=[long](Field $event 'seq' 0)
        if ($null -ne $script:lastSeq -and $seq -gt $script:lastSeq) {
            $script:doneUntil=[DateTime]::Now.AddSeconds(8)
            $script:eventType=Field $event 'type' 'done'
            $script:eventTitle=Field $event 'title' $title
            Notify $(if ($script:eventType -eq 'error') {'任务出错'} else {'任务完成'}) $script:eventTitle
        }
        $script:lastSeq=$seq
    } elseif ($null -eq $script:lastSeq) { $script:lastSeq=0L }
    $pending=Field $state 'pending'
    $count=[int](Field $pending 'count' 0)
    if ($count -gt $script:lastPending) { Notify 'WorkBuddy 等你确认' (Field $pending 'label' '有操作等待确认') }
    $script:lastPending=$count
    if ($count -gt 0) { Show-State 'confirm' '等你确认' (Field $pending 'label' $title) $usageText $ratio '?'; return }
    if ($status -eq 'working') { Show-State 'working' '正在干活' $title $usageText $ratio; return }
    if ($status -eq 'error') { Show-State 'error' '任务出错' $title $usageText $ratio '!'; return }
    if ([DateTime]::Now -lt $script:doneUntil) {
        if ($script:eventType -eq 'error') { Show-State 'error' '任务出错' $script:eventTitle $usageText $ratio '!' }
        else { Show-State 'done' '任务完成' $script:eventTitle $usageText $ratio '✓' }
        return
    }
    $unread=[int](Field $active 'unread' 0)
    if ($unread -gt 0) { Show-State 'unread' '有未读结果' $title $usageText $ratio $(if($unread -gt 9){'9+'}else{[string]$unread}); return }
    Show-State 'idle' '待命' ('上次：'+$title) $usageText $ratio
}
function Find-WorkBuddy {
    foreach ($key in @('HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\WorkBuddy.exe','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\WorkBuddy.exe')) {
        if (Test-Path $key) {
            $value=(Get-Item $key).GetValue('')
            if ($value -and (Test-Path -LiteralPath $value.Trim('"'))) { return $value.Trim('"') }
        }
    }
    $candidates=@((Join-Path $env:LOCALAPPDATA 'Programs\WorkBuddy\WorkBuddy.exe'))
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        if ($drive.IsReady -and $drive.DriveType -eq 'Fixed') { $candidates+=Join-Path $drive.RootDirectory.FullName 'Program Files\WorkBuddy\WorkBuddy.exe' }
    }
    foreach ($candidate in $candidates) { if (Test-Path -LiteralPath $candidate) { return $candidate } }
    return $null
}
function Start-Collector {
    if ($script:worker -and -not $script:worker.HasExited) { return }
    if (([DateTime]::Now-$script:lastWorkerAttempt).TotalSeconds -lt 5) { return }
    $script:lastWorkerAttempt=[DateTime]::Now
    if ($script:worker) {
        if ($script:worker.ExitCode -ne 0) { $script:lastError='采集器退出，代码 '+$script:worker.ExitCode }
        $script:worker.Dispose()
    }
    if (-not (Test-Path -LiteralPath $Python)) { throw '随包 Python 运行时缺失，请完整解压后从 Start.vbs 启动。' }
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$Python
    $info.Arguments='-I -S "'+(Join-Path $PSScriptRoot 'worker.py')+'" --parent '+$PID+' --data "'+$script:dataRoot+'"'
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.WorkingDirectory=$PSScriptRoot
    $script:worker=[Diagnostics.Process]::Start($info)
}
function Tick {
    try {
        Start-Collector
        if (([DateTime]::Now-$script:lastProcessCheck).TotalSeconds -ge 2) {
            $script:lastProcessCheck=[DateTime]::Now
            $processes=@(Get-Process -Name WorkBuddy -ErrorAction SilentlyContinue)
            if ($processes.Count -gt 0) { $script:hasSeenWorkBuddy=$true; $script:misses=0 }
            elseif ($script:hasSeenWorkBuddy) { $script:misses++ }
            if (-not $Stay -and $script:misses -ge 3 -and [DateTime]::Now -gt $script:graceUntil) { $script:window.Close(); return }
            foreach ($process in $processes) { $process.Dispose() }
        }
        if (-not (Test-Path -LiteralPath $script:statePath)) {
            Show-State 'offline' '等待采集器' '正在读取 WorkBuddy 本地数据库' ''
            return
        }
        $state=Get-Content -LiteralPath $script:statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not (Field $state 'error' '') -and -not (Field $state 'stale' $false)) { $script:lastError='' }
        Apply-State $state
    } catch {
        $script:lastError=$_.Exception.Message
        Show-State 'offline' '读数暂时中断' ('等待恢复：'+$script:lastError) ''
    }
}
function Show-Settings {
    if ($script:settings -and $script:settings.IsVisible) { $script:settings.Activate() | Out-Null; return }
    [xml]$markup=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Settings.xaml') -Raw -Encoding UTF8
    $script:settings=[System.Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup))
    if (-not $Smoke) { $script:settings.Owner=$script:window }
    $script:fontSlider=$script:settings.FindName('FontSlider')
    $script:opacitySlider=$script:settings.FindName('OpacitySlider')
    $script:petSlider=$script:settings.FindName('PetSlider')
    $script:fontSlider.Value=$script:cfg.FontSize
    $script:opacitySlider.Value=$script:cfg.PanelOpacity
    $script:petSlider.Value=$script:cfg.PetScale*100
    $script:fontSlider.Add_ValueChanged({ $script:cfg.FontSize=$script:fontSlider.Value; Apply-Configuration; Save-Configuration })
    $script:opacitySlider.Add_ValueChanged({ $script:cfg.PanelOpacity=$script:opacitySlider.Value; Apply-Configuration; Save-Configuration })
    $script:petSlider.Add_ValueChanged({ $script:cfg.PetScale=$script:petSlider.Value/100; Apply-Configuration; Save-Configuration })
    $script:settings.FindName('CloseButton').Add_Click({ $script:settings.Close() })
    if (-not $Smoke) { $script:settings.Show() }
}
function Write-Diagnostics([string]$path) {
        $report=[ordered]@{version=$script:version;host=$PSVersionTable.PSVersion.ToString();application=$PSScriptRoot;worker_running=($script:worker -and -not $script:worker.HasExited);last_error=$script:lastError;database_exists=(Test-Path (Join-Path $env:USERPROFILE '.workbuddy\workbuddy.db'));workbuddy_path=(Find-WorkBuddy)}
        $workerStatus=Join-Path $script:dataRoot 'script-worker.json'
        if (Test-Path $workerStatus) { $report.worker=Get-Content $workerStatus -Raw -Encoding UTF8 | ConvertFrom-Json }
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        $file=[IO.File]::Open($path,[IO.FileMode]::Create)
        $zip=[IO.Compression.ZipArchive]::new($file,[IO.Compression.ZipArchiveMode]::Create)
        try {
            $writer=[IO.StreamWriter]::new($zip.CreateEntry('diagnostic.json').Open(),[Text.UTF8Encoding]::new($false))
            try { $writer.Write(($report | ConvertTo-Json -Depth 8)) } finally { $writer.Dispose() }
        } finally { $zip.Dispose(); $file.Dispose() }
}
function Export-Diagnostics {
    $dialog=[System.Windows.Forms.SaveFileDialog]::new()
    $dialog.Filter='ZIP 文件|*.zip'; $dialog.FileName='WbPet-script-diagnostic.zip'
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { $dialog.Dispose(); return }
    try {
        Write-Diagnostics $dialog.FileName
        [System.Windows.MessageBox]::Show('诊断包已保存，不含会话正文。','WorkBuddy 桌宠') | Out-Null
    } catch { [System.Windows.MessageBox]::Show($_.Exception.Message,'诊断导出失败') | Out-Null }
    finally { $dialog.Dispose() }
}
function Save-Snapshot([string]$path) {
    $root=$script:ui.Root
    $root.Measure([System.Windows.Size]::new(1000,1000))
    $root.Arrange([System.Windows.Rect]::new(0,0,$root.DesiredSize.Width,$root.DesiredSize.Height))
    $root.UpdateLayout()
    $bitmap=[System.Windows.Media.Imaging.RenderTargetBitmap]::new([int][Math]::Ceiling($root.ActualWidth),[int][Math]::Ceiling($root.ActualHeight),96,96,[System.Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($script:ui.Root)
    $encoder=[System.Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream=[IO.File]::Create($path)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
}

try {
    if (-not $Snapshot -and -not $Smoke) {
        $created=$false
        $script:mutex=[Threading.Mutex]::new($true,'Local\WbPet.SingleInstance.v1',[ref]$created)
        if (-not $created) {
            [System.Windows.MessageBox]::Show('已有桌宠正在运行，请先从托盘菜单退出旧版。','WorkBuddy 桌宠') | Out-Null
            return
        }
        [IO.Directory]::CreateDirectory($DataRoot) | Out-Null
        $probe=Join-Path $DataRoot ('write-check-'+[guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe,'ok'); [IO.File]::Delete($probe)
        if (Test-Path -LiteralPath $ConfigPath) {
            try {
                $existing=Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($name in @($script:cfg.Keys)) {
                    $property=$existing.PSObject.Properties[$name]
                    if ($null -ne $property) { $script:cfg[$name]=$property.Value }
                }
            } catch { }
        }
    }
    [xml]$markup=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Main.xaml') -Raw -Encoding UTF8
    $script:window=[System.Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup))
    foreach ($element in $markup.SelectNodes('//*[@*[local-name()="Name"]]')) {
        $attribute=$element.Attributes | Where-Object { $_.LocalName -eq 'Name' } | Select-Object -First 1
        $script:ui[$attribute.Value]=$script:window.FindName($attribute.Value)
    }
    $asset=Join-Path $PSScriptRoot 'Assets\mascot.local.png'
    if (-not (Test-Path $asset)) { $asset=Join-Path $PSScriptRoot 'Assets\mascot.png' }
    $bitmap=[System.Windows.Media.Imaging.BitmapImage]::new()
    $bitmap.BeginInit(); $bitmap.CacheOption='OnLoad'; $bitmap.UriSource=[uri]$asset; $bitmap.EndInit(); $bitmap.Freeze()
    $script:ui.Mascot.Source=$bitmap
    Apply-Configuration
    if ($Snapshot -or $Smoke) {
        $passed=[Collections.Generic.List[string]]::new()
        $state=[pscustomobject]@{ts=[DateTimeOffset]::Now.ToUnixTimeMilliseconds();db_ok=$true;app_running=$true;active=[pscustomobject]@{title='脚本版测试任务';status='working';unread=0};usage=[pscustomobject]@{session_used=250;session_size=1000;credits_today=1.25};pending=[pscustomobject]@{count=0;label=''}}
        Apply-State $state
        if ($script:kind -ne 'working') { throw 'working state failed' }; $passed.Add('working')
        foreach ($fontSize in @(10.0,11.0,18.0)) {
            $script:cfg.FontSize=$fontSize
            Apply-Configuration
            foreach ($fraction in @(0.0,0.263,0.5,0.56,1.0)) {
                $state.usage.session_used=$fraction*1000
                Apply-State $state
                $root=$script:ui.Root
                $root.Measure([System.Windows.Size]::new(1000,1000))
                $root.Arrange([System.Windows.Rect]::new(0,0,$root.DesiredSize.Width,$root.DesiredSize.Height))
                $root.UpdateLayout()
                $width=$script:ui.UsageCol.ActualWidth+$script:ui.RestCol.ActualWidth
                if ($width -le 0) { throw 'progress track has no width' }
                $actual=$script:ui.UsageFill.ActualWidth/$width
                if ([Math]::Abs($actual-$fraction) -gt 0.01) {
                    throw ('progress layout failed: font={0}, expected={1}, drawn={2}' -f $fontSize,$fraction,$actual)
                }
                $expectedText='{0:0.0}%' -f (100*$fraction)
                if (-not $script:ui.UsageText.Text.Contains($expectedText)) { throw 'progress text mismatch' }
                $passed.Add(('progress {0:P1}, font {1}' -f $fraction,$fontSize))
            }
        }
        $script:cfg.FontSize=11.0; Apply-Configuration
        $state.usage.session_used=250; Apply-State $state
        $state.active.status='done'; Apply-State $state
        if ($script:kind -ne 'idle') { throw 'idle state failed' }; $passed.Add('idle')
        $state.active.unread=2; Apply-State $state
        if ($script:kind -ne 'unread') { throw 'unread state failed' }; $passed.Add('unread')
        $state.pending.count=1; $state.pending.label='待确认文件'; Apply-State $state
        if ($script:kind -ne 'confirm') { throw 'pending state failed' }; $passed.Add('pending')
        $state.pending.count=0; $state.active.unread=0; $state.active.status='error'; Apply-State $state
        if ($script:kind -ne 'error') { throw 'error state failed' }; $passed.Add('error')
        $state | Add-Member -NotePropertyName stale -NotePropertyValue $true
        Apply-State $state
        if ($script:kind -ne 'offline' -or $script:ui.UsageText.Visibility -ne 'Collapsed') { throw 'stale state failed' }; $passed.Add('stale hides usage')
        $state.PSObject.Properties.Remove('stale'); $state.active.status='working'; Apply-State $state
        if ($script:kind -ne 'working') { throw 'recovery failed' }; $passed.Add('recovery')
        $state.active.status='completed'
        $state | Add-Member -NotePropertyName event -NotePropertyValue ([pscustomobject]@{seq=1;type='done';title='完成测试'})
        Apply-State $state
        if ($script:kind -ne 'done') { throw 'completion event failed' }; $passed.Add('completion event')
        $state.event.seq=2; $state.event.type='error'; Apply-State $state
        if ($script:kind -ne 'error') { throw 'error event failed' }; $passed.Add('error event')
        if ($Smoke -and $script:canWriteTestConfig) {
            Show-Settings
            $script:fontSlider.Value=16; $script:opacitySlider.Value=70; $script:petSlider.Value=60
            if ($script:cfg.FontSize -ne 16 -or $script:cfg.PanelOpacity -ne 70 -or [Math]::Abs($script:cfg.PetScale-0.6) -gt 0.001) { throw 'settings controls failed' }
            if ([Math]::Abs($script:ui.Bubble.Opacity-0.7) -gt 0.001) { throw 'rendered panel opacity failed' }
            $passed.Add('rendered panel opacity 70%')
            if ([Math]::Abs($script:ui.PetScale.ScaleX-0.6) -gt 0.001 -or [Math]::Abs($script:ui.PetScale.ScaleY-0.6) -gt 0.001) { throw 'rendered pet scale failed' }
            $passed.Add('rendered pet scale 60%')
            $saved=Get-Content -LiteralPath $script:configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($saved.FontSize -ne 16 -or $saved.PanelOpacity -ne 70) { throw ('settings persistence failed: '+$script:lastError) }
            $passed.Add('settings sliders and persistence')
            $script:settings.Close(); $script:settings=$null
            $script:cfg.FontSize=11; $script:cfg.PanelOpacity=95; $script:cfg.PetScale=1; Apply-Configuration
            $diagnosticPath=$script:configPath+'.diagnostic.zip'
            Write-Diagnostics $diagnosticPath
            $archive=[IO.Compression.ZipFile]::OpenRead($diagnosticPath)
            try {
                if ($archive.Entries.Count -ne 1 -or $archive.Entries[0].FullName -ne 'diagnostic.json') { throw 'diagnostic archive failed' }
            } finally { $archive.Dispose() }
            $passed.Add('diagnostic ZIP export')
        }
        $testIcon=[System.Drawing.Icon]::new((Join-Path $PSScriptRoot 'Assets\pet.ico'))
        $testIcon.Dispose(); $passed.Add('tray icon load')
        Stop-Animation
        if ($script:ui.BodyShift.HasAnimatedProperties) { throw 'hidden animation not stopped' }; $passed.Add('hidden animation stops')
        $script:doneUntil=[DateTime]::MinValue; $state.active.status='working'; Apply-State $state
        if ($Snapshot) { Save-Snapshot ([IO.Path]::GetFullPath($Snapshot)) }
        $passed | ConvertTo-Json
        return
    }
    $script:ui.Root.Add_MouseLeftButtonDown({
        try { $script:window.DragMove() } catch { }
        $script:cfg.Left=$script:window.Left; $script:cfg.Top=$script:window.Top; $script:cfg.HasPosition=$true
        Save-Configuration
    })
    $script:ui.MenuTogglePanel.Add_Click({ $script:cfg.ShowPanel=-not $script:cfg.ShowPanel; Apply-Configuration; Save-Configuration })
    $script:ui.MenuLaunchWb.Add_Click({ $script:cfg.LaunchWorkBuddy=[bool]$script:ui.MenuLaunchWb.IsChecked; Save-Configuration })
    $script:ui.MenuTopmost.Add_Click({ $script:cfg.Topmost=[bool]$script:ui.MenuTopmost.IsChecked; Apply-Configuration; Save-Configuration })
    $script:ui.MenuSettings.Add_Click({ Show-Settings })
    $script:ui.MenuHide.Add_Click({ $script:window.Hide() })
    $script:ui.MenuExit.Add_Click({ $script:window.Close() })
    $script:ui.MenuExport.Add_Click({ Export-Diagnostics })
    $script:window.Add_IsVisibleChanged({ Apply-Animation })
    $script:window.Add_KeyDown({ if ($args[1].Key -eq 'Escape') { $script:window.Close() } })
    $script:window.Add_Loaded({
        $workArea=[System.Windows.SystemParameters]::WorkArea
        if ($script:cfg.HasPosition) { $script:window.Left=$script:cfg.Left; $script:window.Top=$script:cfg.Top }
        else { $script:window.Left=$workArea.Right-$script:window.ActualWidth-40; $script:window.Top=$workArea.Bottom-$script:window.ActualHeight-20 }
        $script:window.Left=[Math]::Max($workArea.Left,[Math]::Min($script:window.Left,$workArea.Right-$script:window.ActualWidth))
        $script:window.Top=[Math]::Max($workArea.Top,[Math]::Min($script:window.Top,$workArea.Bottom-$script:window.ActualHeight))
        if ($script:cfg.LaunchWorkBuddy -and -not (Get-Process -Name WorkBuddy -ErrorAction SilentlyContinue)) {
            try {
                $path=Find-WorkBuddy
                if ($path) { Start-Process -FilePath $path | Out-Null }
            } catch { $script:lastError='WorkBuddy 启动失败：'+$_.Exception.GetType().Name }
        }
        Tick
    })
    $script:tray=[System.Windows.Forms.NotifyIcon]::new()
    $script:trayIcon=[System.Drawing.Icon]::new((Join-Path $PSScriptRoot 'Assets\pet.ico'))
    $script:tray.Icon=$script:trayIcon; $script:tray.Text='WorkBuddy 桌宠 '+$script:version
    $trayMenu=[System.Windows.Forms.ContextMenuStrip]::new()
    $trayMenu.Items.Add('版本 '+$script:version).Enabled=$false
    $show=$trayMenu.Items.Add('显示 / 隐藏'); $show.Add_Click({ if ($script:window.IsVisible) {$script:window.Hide()} else {$script:window.Show();$script:window.Activate() | Out-Null} })
    $export=$trayMenu.Items.Add('导出诊断…'); $export.Add_Click({ Export-Diagnostics })
    $exitItem=$trayMenu.Items.Add('退出'); $exitItem.Add_Click({ $script:window.Close() })
    $script:tray.ContextMenuStrip=$trayMenu; $script:tray.Visible=$true
    $script:tray.Add_DoubleClick({ $script:window.Show(); $script:window.Activate() | Out-Null })
    $script:timer=[System.Windows.Threading.DispatcherTimer]::new()
    $script:timer.Interval=[TimeSpan]::FromMilliseconds(350)
    $script:timer.Add_Tick({ Tick }); $script:timer.Start()
    $script:window.ShowDialog() | Out-Null
}
catch {
    try { [IO.File]::WriteAllText((Join-Path $DataRoot 'script-startup-error.txt'),($_ | Out-String)) } catch { }
    if ($Smoke -or $Snapshot) { throw }
    [System.Windows.MessageBox]::Show(('启动失败：'+$_.Exception.Message),'WorkBuddy 桌宠（脚本版）') | Out-Null
}
finally {
    if ($script:timer) { $script:timer.Stop() }
    if ($script:tray) { $script:tray.Visible=$false; $script:tray.Dispose(); $script:trayIcon.Dispose() }
    if ($script:worker) {
        try { if (-not $script:worker.HasExited) { $script:worker.Kill(); $script:worker.WaitForExit(3000) | Out-Null } } catch { }
        $script:worker.Dispose()
    }
    if ($script:mutex) { $script:mutex.Dispose() }
}
