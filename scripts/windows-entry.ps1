#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$MainScript = Join-Path $PSScriptRoot 'windows.ps1'
$BootstrapScript = Join-Path $PSScriptRoot 'bootstrap-tunnel.ps1'
$ServiceScript = Join-Path $PSScriptRoot 'windows-tunnel-service.ps1'
$Runtime = Join-Path $Root '.runtime'
$TunnelExe = Join-Path $Runtime 'bin\tunnel-client.exe'
$ChildPowerShell = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $ChildPowerShell -PathType Leaf)) {
    $ChildPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
}
$script:EntryExitCode = 1
$command = if ($args.Count -gt 0) { ([string]$args[0]).ToLowerInvariant() } else { 'help' }
$serviceCommands = @('service-install','service-start','service-stop','service-restart','service-status','service-uninstall')
$known = @('help','install','start','stop','restart','apply','status','logs','update','tunnel-run') + $serviceCommands

function Invoke-ScriptStep([string]$Path, [string[]]$Arguments) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing script: $Path" }
    & $ChildPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        $script:EntryExitCode = $code
        throw "$(Split-Path -Leaf $Path) failed (exit $code)."
    }
}

function Ensure-TunnelClient([bool]$Force) {
    if (-not $Force -and (Test-Path -LiteralPath $TunnelExe -PathType Leaf)) { return }
    Write-Host $(if ($Force) { '==> Updating tunnel-client' } else { '==> Preparing tunnel-client' })
    Invoke-ScriptStep -Path $BootstrapScript -Arguments @()
}

function Show-ControlPlaneStatus {
    if (Test-ControlPlaneConnected -RuntimeDir $Runtime) {
        Write-Host 'Control Plane : CONNECTED' -ForegroundColor Green
        return $true
    }
    Write-Host 'Control Plane : UNVERIFIED' -ForegroundColor Yellow
    return $false
}

try {
    if ($args.Count -gt 1 -or $command -notin $known) {
        [Console]::Error.WriteLine('Usage: .\agentdock.cmd {install|start|stop|restart|apply|status|logs|update|service-install|service-start|service-stop|service-restart|service-status|service-uninstall|help}')
        exit 2
    }

    . (Join-Path $PSScriptRoot 'windows-runtime-checks.ps1')

    if ($command -in @('install','start','restart','apply','update','tunnel-run','service-install','service-start','service-restart')) {
        Configure-TunnelProxy
    }

    if ($command -in $serviceCommands) {
        $subcommand = $command.Substring('service-'.Length)
        if ($command -eq 'service-install') {
            Ensure-TunnelClient $false
            Invoke-ScriptStep -Path $MainScript -Arguments @('install')
        }
        Invoke-ScriptStep -Path $ServiceScript -Arguments @($subcommand)

        if ($command -eq 'service-status') {
            Invoke-ScriptStep -Path $MainScript -Arguments @('status')
            [void](Show-ControlPlaneStatus)
        } elseif ($command -in @('service-install','service-start','service-restart')) {
            if (-not (Wait-ControlPlaneConnected -RuntimeDir $Runtime)) {
                Write-Host 'Control Plane : UNVERIFIED' -ForegroundColor Yellow
                [Console]::Error.WriteLine('The scheduled tunnel task is running, but no recent control-plane poll was verified. It has NOT been stopped.')
                exit 2
            }
            Write-Host 'Control Plane : CONNECTED' -ForegroundColor Green
            Write-Host 'Verify end-to-end access with a read-only tool call in ChatGPT.'
        }
        exit 0
    }

    if ($command -in @('install','start','restart','apply')) {
        Ensure-TunnelClient $false
    } elseif ($command -eq 'update') {
        Ensure-TunnelClient $true
    }

    $modePath = Join-Path $Runtime 'deployment.txt'
    $wslManaged = (Test-Path -LiteralPath $modePath -PathType Leaf) -and ((Get-Content -LiteralPath $modePath -Raw).Trim() -eq 'docker-wsl')
    if ($wslManaged -and $command -in @('start','restart','apply','stop','status')) {
        . (Join-Path $PSScriptRoot 'windows-wsl-session.ps1')
        if ($command -in @('start','restart','apply')) {
            Start-AgentDockWslSession -RuntimeDir $Runtime -HelperScript (Join-Path $PSScriptRoot 'wsl-session.sh')
        } elseif ($command -eq 'stop' -and (Test-Path -LiteralPath (Join-Path $Runtime 'wsl-session.json'))) {
            [void](Assert-WslSessionDefault -RuntimeDir $Runtime)
        }
    }

    Invoke-ScriptStep -Path $MainScript -Arguments @($command)

    if ($command -eq 'tunnel-run') { exit 0 }

    if ($wslManaged -and $command -eq 'stop') {
        Stop-AgentDockWslSession -RuntimeDir $Runtime
    }
    if ($wslManaged -and $command -eq 'status') { Show-AgentDockWslSession -RuntimeDir $Runtime }

    if ($command -in @('start','restart','apply')) {
        if (-not (Wait-ControlPlaneConnected -RuntimeDir $Runtime)) {
            Write-Host 'Control Plane : UNVERIFIED' -ForegroundColor Yellow
            [Console]::Error.WriteLine('Local services may be running, but this tunnel has no verified recent control-plane poll. They have NOT been stopped.')
            [Console]::Error.WriteLine('Run .\agentdock.cmd status and .\agentdock.cmd logs; check the proxy/network and Tunnel permissions. Exit code: 2.')
            exit 2
        }
        Write-Host 'Control Plane : CONNECTED' -ForegroundColor Green
        Write-Host 'Verify end-to-end access with a read-only tool call in ChatGPT.'
    } elseif ($command -eq 'status') {
        [void](Show-ControlPlaneStatus)
    }
    exit 0
} catch {
    [Console]::Error.WriteLine("ERROR: Windows command '$command' failed. " + $_.Exception.Message)
    [Console]::Error.WriteLine('No configuration or runtime data was deleted. Run .\agentdock.cmd logs for service diagnostics; redact secrets before sharing.')
    [Console]::Error.WriteLine('An existing WSL keepalive is retained on service errors. Use .\agentdock.cmd stop after diagnosis to release it.')
    exit $script:EntryExitCode
}
