# One-command launcher: builds if needed, keeps a persistent token, starts the
# server and a Cloudflare quick tunnel, and prints what to paste into ChatGPT.
# Works in Windows PowerShell 5.1 and PowerShell 7.
param(
    # Folders Claude Code may work in. Default: the folder that contains this repo.
    [string[]]$Root,
    [int]$Port = 8765,
    [string]$Claude = "claude",
    # Only run locally (no tunnel).
    [switch]$NoTunnel
)

$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
if (-not $Root) { $Root = @(Split-Path $repo -Parent) }

function Say($msg, $color = "Gray") { Write-Host $msg -ForegroundColor $color }

# 1. Build if the binary is missing.
$exe = Join-Path $repo "zig-out\bin\claudegpt.exe"
if (-not (Test-Path $exe)) {
    Say "Building claudegpt (first run)..." Cyan
    if (-not (Get-Command zig -ErrorAction SilentlyContinue)) {
        throw "zig not found. Install Zig 0.16 (winget install zig.zig) and try again."
    }
    Push-Location $repo
    try { zig build -Doptimize=ReleaseSafe; if ($LASTEXITCODE) { throw "zig build failed" } }
    finally { Pop-Location }
}

# 2. Token: generated once, reused so the ChatGPT connector keeps working.
$tokenFile = Join-Path $env:USERPROFILE ".claudegpt\token"
if (-not (Test-Path $tokenFile)) {
    New-Item -ItemType Directory -Force (Split-Path $tokenFile) | Out-Null
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    (($bytes | ForEach-Object { $_.ToString("x2") }) -join "") | Set-Content -NoNewline $tokenFile
}
$token = (Get-Content -Raw $tokenFile).Trim()
$env:CLAUDEGPT_TOKEN = $token

# 3. Sanity-check claude.
if (-not (Get-Command $Claude -ErrorAction SilentlyContinue) -and -not (Test-Path $Claude)) {
    throw "'$Claude' not found. Install Claude Code and make sure 'claude -p hi' works."
}

# 4. Start the server.
$serverArgs = @("--port", $Port, "--claude-path", "`"$Claude`"")
foreach ($r in $Root) { $serverArgs += @("--root", "`"$r`"") }
$server = Start-Process -FilePath $exe -ArgumentList $serverArgs -NoNewWindow -PassThru
$tunnel = $null
try {
    $healthy = $false
    for ($i = 0; $i -lt 50 -and -not $healthy; $i++) {
        Start-Sleep -Milliseconds 200
        if ($server.HasExited) { throw "claudegpt exited (code $($server.ExitCode)); see the messages above." }
        try { $healthy = (Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$Port/healthz").StatusCode -eq 200 } catch {}
    }
    if (-not $healthy) { throw "claudegpt did not come up on port $Port." }

    $url = "http://127.0.0.1:$Port/mcp"
    if (-not $NoTunnel) {
        # 5. Tunnel.
        $cf = Get-Command cloudflared -ErrorAction SilentlyContinue
        if (-not $cf) {
            $known = @("${env:ProgramFiles(x86)}\cloudflared\cloudflared.exe", "$env:ProgramFiles\cloudflared\cloudflared.exe")
            $found = $known | Where-Object { Test-Path $_ } | Select-Object -First 1
            if (-not $found) {
                Say "Installing cloudflared with winget..." Cyan
                winget install --id Cloudflare.cloudflared -e --accept-source-agreements --accept-package-agreements | Out-Null
                $found = $known | Where-Object { Test-Path $_ } | Select-Object -First 1
            }
            if (-not $found) { throw "cloudflared not found. Install it (winget install Cloudflare.cloudflared), reopen the terminal, and retry." }
            $cfPath = $found
        } else { $cfPath = $cf.Source }

        $log = Join-Path $env:TEMP "claudegpt-tunnel.log"
        Remove-Item $log -ErrorAction SilentlyContinue
        $tunnel = Start-Process -FilePath $cfPath -ArgumentList @("tunnel", "--url", "http://127.0.0.1:$Port") `
            -NoNewWindow -PassThru -RedirectStandardError $log -RedirectStandardOutput "$log.out"
        $public = $null
        for ($i = 0; $i -lt 120 -and -not $public; $i++) {
            Start-Sleep -Milliseconds 500
            if ($tunnel.HasExited) { throw "cloudflared exited; see $log" }
            if (Test-Path $log) {
                $m = Select-String -Path $log -Pattern "https://[-a-z0-9]+\.trycloudflare\.com" | Select-Object -First 1
                if ($m) { $public = $m.Matches[0].Value }
            }
        }
        if (-not $public) { throw "No tunnel URL after 60 s; see $log" }
        $url = "$public/mcp"
    }

    try { Set-Clipboard -Value $url } catch {}
    Say ""
    Say "  ClaudeGpt is running." Green
    Say "  Connector URL (copied to clipboard): $url" Yellow
    Say "  Bearer token:                        $token" Yellow
    Say "  Claude Code may work in:             $($Root -join ', ')"
    Say "  Press Ctrl+C to stop."
    Say ""
    Wait-Process -Id $server.Id
}
finally {
    foreach ($p in @($tunnel, $server)) {
        if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
}
