param(
    [Parameter(Mandatory=$true)][string]$Package,
    [Parameter(Mandatory=$true)][string]$TargetRoot,
    [Parameter(Mandatory=$true)][string]$ExpectedSha256,
    [int]$ParentPid=0,
    [int]$LauncherPid=0,
    [string]$RelaunchExe='XenusDRO2Tool.exe',
    [string]$TargetChannel=''
)
$ErrorActionPreference='Stop'
$work=Split-Path -Parent $MyInvocation.MyCommand.Path
$persistentLogDir=Join-Path $env:LOCALAPPDATA 'XenusDRO2Tool\Logs'
try{New-Item -ItemType Directory -Force -Path $persistentLogDir|Out-Null}catch{}
$log=Join-Path $persistentLogDir 'updater.log'
function Log([string]$m){try{Add-Content -LiteralPath $log -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')+' | '+$m) -Encoding UTF8}catch{}}
Log 'Updater bootstrap entered.'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class XenusUpdaterWindowNative {
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
}
'@

$form=New-Object System.Windows.Forms.Form
$form.Text="Xenu's DRO2 Tool - Updater"
$form.ClientSize=New-Object System.Drawing.Size(470,150)
$form.FormBorderStyle=[System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox=$false;$form.MinimizeBox=$false;$form.ControlBox=$false
$form.StartPosition=[System.Windows.Forms.FormStartPosition]::CenterScreen
$form.TopMost=$true
$title=New-Object System.Windows.Forms.Label
$title.Text='Switching branch...';$title.AutoSize=$false;$title.Location=New-Object System.Drawing.Point(24,20);$title.Size=New-Object System.Drawing.Size(420,24)
$title.Font=New-Object System.Drawing.Font('Segoe UI',11,[System.Drawing.FontStyle]::Bold)
$form.Controls.Add($title)
$status=New-Object System.Windows.Forms.Label
$status.Text='Preparing update';$status.AutoSize=$false;$status.Location=New-Object System.Drawing.Point(24,52);$status.Size=New-Object System.Drawing.Size(420,22)
$form.Controls.Add($status)
$bar=New-Object System.Windows.Forms.ProgressBar
$bar.Location=New-Object System.Drawing.Point(24,82);$bar.Size=New-Object System.Drawing.Size(420,22);$bar.Minimum=0;$bar.Maximum=100;$bar.Value=5
$form.Controls.Add($bar)
$hint=New-Object System.Windows.Forms.Label
$hint.Text="Please don't reopen the tool; it will restart automatically.";$hint.AutoSize=$false;$hint.Location=New-Object System.Drawing.Point(24,112);$hint.Size=New-Object System.Drawing.Size(420,20)
$form.Controls.Add($hint)
$form.ShowInTaskbar=$true
Log 'Creating updater progress window.'
$form.Show();$form.Refresh();[System.Windows.Forms.Application]::DoEvents()
$hwnd=$form.Handle
[XenusUpdaterWindowNative]::ShowWindow($hwnd,5)|Out-Null
$form.TopMost=$true
$form.BringToFront();$form.Activate();$form.Focus()
[XenusUpdaterWindowNative]::BringWindowToTop($hwnd)|Out-Null
[XenusUpdaterWindowNative]::SetForegroundWindow($hwnd)|Out-Null
[System.Windows.Forms.Application]::DoEvents()
Log ('Updater progress window shown. Handle='+$hwnd)
function Set-Step([string]$text,[int]$pct){
    $status.Text=$text;$bar.Value=[Math]::Max(0,[Math]::Min(100,$pct))
    if(-not $form.TopMost){$form.TopMost=$true}
    $form.Refresh();[System.Windows.Forms.Application]::DoEvents()
}
function Wait-Exit([int]$id,[int]$loops=80){
    if($id -le 0){return $true}
    for($i=0;$i -lt $loops;$i++){
        if(-not (Get-Process -Id $id -ErrorAction SilentlyContinue)){return $true}
        [System.Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 250
    }
    return $false
}
function Stop-OldLauncherIfNeeded([int]$id){
    if($id -le 0){return}
    if(Wait-Exit $id 20){return}
    Log ('Old launcher wrapper still active after runtime exit; terminating pid '+$id)
    try{Stop-Process -Id $id -Force -ErrorAction Stop}catch{throw ('Old launcher process '+$id+' could not be closed: '+$_.Exception.Message)}
    if(-not (Wait-Exit $id 20)){throw ('Old launcher process '+$id+' is still active after termination request.')}
}
function Wait-UiReady([string]$marker,[int]$seconds=35){
    $deadline=(Get-Date).AddSeconds($seconds)
    while((Get-Date) -lt $deadline){
        if(Test-Path -LiteralPath $marker){return $true}
        if(-not $form.TopMost){$form.TopMost=$true}
        $form.Refresh();[System.Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 200
    }
    return $false
}
$updateData=Join-Path $TargetRoot 'UpdateData'
$stagingRoot=Join-Path $updateData 'Staging'
$rollbackRoot=Join-Path $updateData 'Rollback'
$stamp=Get-Date -Format 'yyyyMMdd_HHmmss'
$stage=Join-Path $stagingRoot $stamp
$backup=Join-Path $rollbackRoot $stamp
try{New-Item -ItemType Directory -Force -Path $stagingRoot,$rollbackRoot|Out-Null}catch{}
try{
    Log 'Updater helper started.'
    Set-Step 'Closing current tool...' 10
    if(-not (Wait-Exit $ParentPid 80)){throw ('Runtime process '+$ParentPid+' did not exit in time.')}
    Stop-OldLauncherIfNeeded $LauncherPid
    Set-Step 'Verifying update package...' 22
    $sha=(Get-FileHash -LiteralPath $Package -Algorithm SHA256).Hash.ToLowerInvariant()
    if($sha -ne $ExpectedSha256.ToLowerInvariant()){throw 'Staged package SHA256 mismatch.'}
    Set-Step 'Preparing new files...' 35
    if(Test-Path $stage){Remove-Item -LiteralPath $stage -Recurse -Force}
    New-Item -ItemType Directory -Force -Path $stage|Out-Null
    Expand-Archive -LiteralPath $Package -DestinationPath $stage -Force
    $items=@(Get-ChildItem -LiteralPath $stage -Force)
    $payload=$stage
    if($items.Count -eq 1 -and $items[0].PSIsContainer){$payload=$items[0].FullName}
    foreach($required in @('XenusDRO2Tool.exe','DRO2DiagnosticBridge.dll','XenusDRO2Updater.ps1')){if(-not (Test-Path -LiteralPath (Join-Path $payload $required))){throw ('Package missing required file: '+$required)}}
    $ps=@(Get-ChildItem -LiteralPath $payload -Filter 'Xenus_DRO2_Tool_*.ps1' -File)
    if($ps.Count -ne 1){throw ('Package must contain exactly one runtime PS1; found '+$ps.Count)}
    Set-Step 'Creating rollback copy...' 52
    if(Test-Path $backup){Remove-Item -LiteralPath $backup -Recurse -Force}
    New-Item -ItemType Directory -Force -Path $backup|Out-Null
    Get-ChildItem -LiteralPath $TargetRoot -Force | Where-Object {$_.Name -ne 'UpdateData'} | ForEach-Object {Copy-Item -LiteralPath $_.FullName -Destination $backup -Recurse -Force}
    try{
        Set-Step 'Installing selected branch...' 70
        Get-ChildItem -LiteralPath $TargetRoot -Force | Where-Object {$_.Name -ne 'UpdateData'} | Remove-Item -Recurse -Force
        Get-ChildItem -LiteralPath $payload -Force | ForEach-Object {Copy-Item -LiteralPath $_.FullName -Destination $TargetRoot -Recurse -Force}
        Log ('Install committed. Rollback: '+$backup)
        if(@('stable','testing') -contains $TargetChannel){
            try{
                Set-Step 'Saving branch selection...' 84
                $cfgDir=Join-Path $env:LOCALAPPDATA 'XenusDRO2Tool';$cfgPath=Join-Path $cfgDir 'settings.json'
                New-Item -ItemType Directory -Force -Path $cfgDir|Out-Null
                $cfg=$null
                if(Test-Path -LiteralPath $cfgPath){try{$cfg=Get-Content -LiteralPath $cfgPath -Raw|ConvertFrom-Json}catch{}}
                if($null -eq $cfg){$cfg=[pscustomobject]@{SchemaVersion=3;DarkMode=$false;UpdateChannel=$TargetChannel;NicknameChatName='';NicknameOverheadName=''}}else{$cfg.UpdateChannel=$TargetChannel}
                $cfg|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $cfgPath -Encoding UTF8
                Log ('Active branch persisted: '+$TargetChannel)
            }catch{Log ('WARNING: could not persist active branch: '+$_.Exception.Message)}
        }
    }catch{
        Log ('Install failed; restoring rollback: '+$_.Exception.Message)
        Get-ChildItem -LiteralPath $TargetRoot -Force | Where-Object {$_.Name -ne 'UpdateData'} | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $backup -Force | ForEach-Object {Copy-Item -LiteralPath $_.FullName -Destination $TargetRoot -Recurse -Force -ErrorAction SilentlyContinue}
        throw
    }
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    @(Get-ChildItem -LiteralPath $rollbackRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -Skip 2) | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Set-Step "Starting updated tool..." 96
    $exe=Join-Path $TargetRoot $RelaunchExe
    if(-not (Test-Path $exe)){throw 'Updated launcher executable is missing.'}
    $readyMarker=Join-Path $env:TEMP ('XenusDRO2Tool_UIReady_'+[guid]::NewGuid().ToString('N')+'.txt')
    Remove-Item -LiteralPath $readyMarker -Force -ErrorAction SilentlyContinue
    $oldReadyMarker=$env:XENUS_UI_READY_MARKER
    $env:XENUS_UI_READY_MARKER=$readyMarker
    try{Start-Process -FilePath $exe -WorkingDirectory $TargetRoot|Out-Null}finally{
        if($null -eq $oldReadyMarker){Remove-Item Env:XENUS_UI_READY_MARKER -ErrorAction SilentlyContinue}else{$env:XENUS_UI_READY_MARKER=$oldReadyMarker}
    }
    Log ('Relaunch requested. Waiting for UI-ready marker: '+$readyMarker)
    Set-Step 'Waiting for updated tool window...' 98
    if(Wait-UiReady $readyMarker 35){
        Log 'Updated tool UI confirmed visible.'
        Set-Step 'Updated tool is ready' 100
        Start-Sleep -Milliseconds 900
    }else{
        Log 'WARNING: updated tool UI was not confirmed within 35 seconds; leaving updater visible briefly.'
        $status.Text='Tool started, but UI confirmation timed out. Check Tool logs if needed.'
        $bar.Value=99;$form.Refresh();[System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Seconds 3
    }
    Remove-Item -LiteralPath $readyMarker -Force -ErrorAction SilentlyContinue
    $form.Close()
}catch{
    Log ('FAILED: '+$_.Exception.Message+' | '+$_.ScriptStackTrace)
    try{$form.Close()}catch{}
    try{[System.Windows.Forms.MessageBox]::Show(('Update failed. The previous installation was kept/restored when possible.'+"`r`n`r`n"+$_.Exception.Message),"Xenu's DRO2 Tool Updater")|Out-Null}catch{}
    exit 1
}
