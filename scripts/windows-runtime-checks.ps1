#requires -Version 5.1
# Local diagnostics only; this file never installs or starts a service.
function Normalize-ProxyUrl([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $v = $Value.Trim()
    if ($v -match '^[A-Za-z][A-Za-z0-9+.-]*://') { return $v }
    return "http://$v"
}

function Get-SystemProxy {
    # Two sources: the static registry ProxyServer (ProxyEnable=1), and PAC/WPAD
    # auto-proxy. PAC setups (common on corporate networks) leave ProxyEnable=0
    # and only set AutoConfigURL, so the registry branch returns nothing. Resolve
    # those through .NET's system web proxy, which evaluates the PAC and yields
    # the concrete HTTP(S) proxy for a given URL. Loopback stays bypassed.
    $http = $null
    $https = $null
    try {
        $settings = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ([int]$settings.ProxyEnable -eq 1) {
            $raw = [string]$settings.ProxyServer
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                if ($raw.Contains('=')) {
                    foreach ($part in ($raw -split ';')) {
                        $pair = $part.Split('=', 2)
                        if ($pair.Count -ne 2) { continue }
                        $value = Normalize-ProxyUrl $pair[1]
                        switch ($pair[0].Trim().ToLowerInvariant()) {
                            'http' { $http = $value; if (-not $https) { $https = $value } }
                            'https' { $https = $value; if (-not $http) { $http = $value } }
                        }
                    }
                } else {
                    $http = Normalize-ProxyUrl $raw
                    $https = $http
                }
            }
        }
    } catch { $http = $null; $https = $null }

    # PAC/WPAD resolution: ask the system web proxy for the proxy that would be
    # used for an external HTTPS host, e.g. api.openai.com. If it yields a real
    # proxy and that host is not bypassed, use it. api.openai.com is a reasonable
    # stand-in for "external internet"; internal-only PACs typically bypass it.
    try {
        $sys = [Net.WebRequest]::GetSystemWebProxy()
        $test = [Uri]'https://api.openai.com/'
        if (-not $sys.IsBypassed($test)) {
            $resolved = $sys.GetProxy($test)
            if ($null -ne $resolved -and $resolved.Authority) {
                $auto = 'http://' + $resolved.Authority
                if (-not $http) { $http = $auto }
                if (-not $https) { $https = $auto }
            }
        }
    } catch { }

    if (-not $https) { $https = $http }
    if (-not $http) { $http = $https }
    if (-not $http -and -not $https) { return $null }
    return [pscustomobject]@{ Http=$http; Https=$https }
}

function Add-LoopbackNoProxy {
    $items = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($env:NO_PROXY)) {
        foreach ($item in ($env:NO_PROXY -split '[,;]')) {
            $v = $item.Trim()
            if ($v -and -not $items.Contains($v)) { $items.Add($v) }
        }
    }
    foreach ($required in @('127.0.0.1','localhost','::1')) {
        if (-not $items.Contains($required)) { $items.Add($required) }
    }
    $env:NO_PROXY = $items -join ','
}

function Configure-TunnelProxy {
    $source = $null
    if (-not [string]::IsNullOrWhiteSpace($env:HTTPS_PROXY) -or -not [string]::IsNullOrWhiteSpace($env:HTTP_PROXY)) {
        if ([string]::IsNullOrWhiteSpace($env:HTTPS_PROXY)) { $env:HTTPS_PROXY = $env:HTTP_PROXY }
        if ([string]::IsNullOrWhiteSpace($env:HTTP_PROXY)) { $env:HTTP_PROXY = $env:HTTPS_PROXY }
        $source = 'environment'
    } else {
        $proxy = Get-SystemProxy
        if ($null -ne $proxy) {
            $env:HTTP_PROXY = $proxy.Http
            $env:HTTPS_PROXY = $proxy.Https
            $source = 'Windows System Proxy'
        }
    }
    Add-LoopbackNoProxy
    # A URL can contain credentials. Log only its source, never the full value.
    if ($source) { Write-Host "Tunnel proxy : $source (credentials hidden)" }
}

function Get-PollTimestamp([string]$Content) {
    $latest = 0.0
    foreach ($line in ($Content -split "`n")) {
        if ($line -match '^commands_poll_last_successful_timestamp_seconds(?:\{[^}]*\})?\s+([0-9eE+.-]+)\s*$') {
            $value = 0.0
            if ([double]::TryParse($matches[1], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
                if (-not [double]::IsInfinity($value) -and -not [double]::IsNaN($value) -and $value -gt $latest) { $latest = $value }
            }
        }
    }
    return $latest
}

function Get-TunnelMetricsAddr([string]$RuntimeDir) {
    # The tunnel-client health/metrics server binds 127.0.0.1:8080 by default.
    # It may be relocated via config (metrics_port); windows.ps1 records the
    # resolved port in a metrics-port file inside $RuntimeDir so this orchestrator
    # (a separate process) can verify the right listener. AGENTDOCK_METRICS_PORT
    # overrides the default. Never use a proxy for the loopback endpoint.
    $portFile = Join-Path $RuntimeDir 'tunnel-metrics.port'
    if (Test-Path -LiteralPath $portFile -PathType Leaf) {
        $v = (Get-Content -LiteralPath $portFile -Raw).Trim()
        if ($v -match '^\d+$') { return "127.0.0.1:$v" }
    }
    $port = $env:AGENTDOCK_METRICS_PORT
    if ($port -match '^\d+$') { return "127.0.0.1:$port" }
    return '127.0.0.1:8080'
}

function Read-LocalTunnelMetrics([string]$RuntimeDir) {
    # Never use a proxy for the loopback diagnostics endpoint.
    $request = [Net.WebRequest]::Create('http://' + (Get-TunnelMetricsAddr $RuntimeDir) + '/metrics')
    $request.Proxy = $null
    $request.Timeout = 2000
    $request.ReadWriteTimeout = 2000
    $response = $request.GetResponse()
    try {
        $reader = New-Object IO.StreamReader($response.GetResponseStream())
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $response.Close() }
}

function Test-ControlPlaneConnected([string]$RuntimeDir) {
    # Current releases default to metrics port 8080. If it is moved/disabled, or
    # provenance cannot be established, report UNVERIFIED rather than guessing.
    try {
        $pidPath = Join-Path $RuntimeDir 'tunnel-client.pid'
        if (-not (Test-Path -LiteralPath $pidPath -PathType Leaf)) { return $false }
        $text = (Get-Content -LiteralPath $pidPath -Raw).Trim()
        $processId = 0
        if (-not [int]::TryParse($text, [ref]$processId) -or $processId -le 0) { return $false }
        $process = Get-Process -Id $processId -ErrorAction Stop
        $expected = [IO.Path]::GetFullPath((Join-Path $RuntimeDir 'bin\tunnel-client.exe'))
        if (-not [string]::Equals($process.Path, $expected, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        $addr = Get-TunnelMetricsAddr $RuntimeDir
        $port = ([uri]"http://$addr").Port
        $listeners = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction Stop)
        $owners = @($listeners | Select-Object -ExpandProperty OwningProcess -Unique)
        if ($owners.Count -ne 1 -or $owners[0] -ne $processId) { return $false }

        $content = Read-LocalTunnelMetrics $RuntimeDir
        $stamp = Get-PollTimestamp $content
        $epoch = [DateTime]::SpecifyKind([DateTime]'1970-01-01', [DateTimeKind]::Utc)
        $now = ([DateTime]::UtcNow - $epoch).TotalSeconds
        $started = ($process.StartTime.ToUniversalTime() - $epoch).TotalSeconds
        return ($stamp -gt 0 -and $stamp -ge $started - 2 -and $stamp -ge $now - 120 -and $stamp -le $now + 5)
    } catch { return $false }
}

function Wait-ControlPlaneConnected([string]$RuntimeDir) {
    for ($i = 0; $i -lt 30; $i++) {
        if (Test-ControlPlaneConnected -RuntimeDir $RuntimeDir) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}
