#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$Runtime = Join-Path $Root '.runtime'
$ModePath = Join-Path $Runtime 'deployment.txt'
$TunnelPid = Join-Path $Runtime 'tunnel-client.pid'
$EntryScript = Join-Path $PSScriptRoot 'windows-entry.ps1'
$TaskName = 'AgentDock Secure Tunnel'
$TaskPath = '\AgentDock\'
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Fail([string]$Message) { throw $Message }

function Get-TunnelTask {
    try { return Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop } catch { return $null }
}

function Assert-ExternalInstalled {
    if (-not (Test-Path -LiteralPath $ModePath -PathType Leaf)) { Fail 'Run .\agentdock.cmd install first.' }
    $mode = (Get-Content -LiteralPath $ModePath -Raw).Trim()
    if ($mode -ne 'external') { Fail 'Windows background service commands require deployment_mode: external.' }
}

function Stop-TunnelPid {
    if (-not (Test-Path -LiteralPath $TunnelPid -PathType Leaf)) { return }
    $text = (Get-Content -LiteralPath $TunnelPid -Raw).Trim()
    $processId = 0
    if ([int]::TryParse($text,[ref]$processId) -and $processId -gt 0) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $TunnelPid -Force -ErrorAction SilentlyContinue
}

function Register-TunnelTask {
    Assert-ExternalInstalled
    if (-not (Test-Path -LiteralPath $EntryScript -PathType Leaf)) { Fail "Missing entry script: $EntryScript" }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" tunnel-run' -f $EntryScript
    $action = New-ScheduledTaskAction -Execute $PowerShellExe -Argument $arguments -WorkingDirectory $Root
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
    $principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -MultipleInstances IgnoreNew
    $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'OpenAI Secure MCP Tunnel for the existing local AgentDock instance.'
    Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -InputObject $task -Force | Out-Null
}

function Start-TunnelTask {
    Assert-ExternalInstalled
    $task = Get-TunnelTask
    if ($null -eq $task) { Fail 'Scheduled task is not installed. Run .\agentdock.cmd service-install.' }
    if ([string]$task.State -ne 'Running') { Start-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath }
    for ($i=0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        $current = Get-TunnelTask
        if ($null -ne $current -and [string]$current.State -eq 'Running') { return }
    }
    Fail 'AgentDock Secure Tunnel scheduled task did not enter Running state.'
}

function Stop-TunnelTask {
    $task = Get-TunnelTask
    if ($null -ne $task -and [string]$task.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    }
    Stop-TunnelPid
}

function Show-TunnelTaskStatus {
    $task = Get-TunnelTask
    if ($null -eq $task) {
        Write-Host 'Scheduled Task : NOT INSTALLED'
        return
    }
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath
    Write-Host "Scheduled Task : $($task.State)"
    Write-Host "Task Name      : $TaskPath$TaskName"
    Write-Host "Last Result    : $($info.LastTaskResult)"
    if ($info.LastRunTime -and $info.LastRunTime.Year -gt 2000) { Write-Host "Last Run       : $($info.LastRunTime)" }
}

function Install-Service {
    Assert-ExternalInstalled
    Stop-TunnelTask
    Register-TunnelTask
    Start-TunnelTask
    Write-Host 'Installed Windows login task: AgentDock Secure Tunnel' -ForegroundColor Green
    Show-TunnelTaskStatus
}

function Restart-Service {
    Assert-ExternalInstalled
    Stop-TunnelTask
    Start-TunnelTask
    Show-TunnelTaskStatus
}

function Uninstall-Service {
    Stop-TunnelTask
    if ($null -ne (Get-TunnelTask)) {
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false
    }
    Write-Host 'Uninstalled Windows login task: AgentDock Secure Tunnel'
}

$Command = if ($args.Count -gt 0) { ([string]$args[0]).ToLowerInvariant() } else { 'status' }
switch ($Command) {
    'install' { Install-Service }
    'start' { Start-TunnelTask; Show-TunnelTaskStatus }
    'stop' { Stop-TunnelTask; Show-TunnelTaskStatus }
    'restart' { Restart-Service }
    'status' { Show-TunnelTaskStatus }
    'uninstall' { Uninstall-Service }
    default { Fail 'usage: windows-tunnel-service.ps1 {install|start|stop|restart|status|uninstall}' }
}
