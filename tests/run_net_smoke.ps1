# run_net_smoke.ps1 — Sprint 21 two-instance multiplayer smoke test.
#
# Launches TWO local game instances that auto-drive the menu (no clicking) via the
# NetworkManager "--net-smoke" autopilot, connect to each other, run the unified
# rollback handshake, and start delta_rollback's SyncManager. Each instance prints
#   [NET-SMOKE] sync_started ...
#   [NET-SMOKE] tick=60 fp=Player=(..) Opponent=(..)
#   [NET-SMOKE] OK
# SUCCESS = both logs reach "[NET-SMOKE] OK" AND their fp= fingerprints MATCH
# (identical deterministic wizard positions => the rollback sim is in lockstep).
#
# Usage:
#   pwsh tests/run_net_smoke.ps1            # LAN (ENet) — no server needed
#   pwsh tests/run_net_smoke.ps1 -Mode online
#
# ONLINE prerequisite: a local Nakama server in Docker must be up first:
#   docker run -d -p 7350:7350 -p 7351:7351 ... heroiclabs/nakama   (key: defaultkey)
#
# NOTE on the two-instance import lock (bug graveyard): two Godot processes that
# both IMPORT the same project at once deadlock on .godot/. This script imports
# ONCE up front, then launches the two GAME instances (no import), so they don't
# contend. If you ever see them hang on first run, import once manually
# (`godot --headless --import`) or copy the project to a second folder for the
# client. The instances run WINDOWED (not headless) for the same reason.

param(
    [ValidateSet("lan", "online")] [string]$Mode = "lan",
    [int]$TimeoutSeconds = 40,
    # Windowed by default so you can WATCH the two clients. -Headless runs both
    # without windows (robust for automated/CI verification; imports happen once
    # up front so the two game runs don't contend on .godot/).
    [switch]$Headless
)

# NOTE: do NOT use "Stop" here — Godot writes harmless GDExtension warnings
# (e.g. DPITexture) to stderr, and PowerShell 5.1 would wrap those into a
# terminating NativeCommandError. We drive success/failure from the logs instead.
$ErrorActionPreference = "Continue"
# Godot 4.6.3-stable (Creative Director mandate — 4.6.1 has GDExtension regressions vs delta_rollback).
$Godot = "C:/Users/laure/Downloads/Godot_v4.6.3-stable_win64.exe/Godot_v4.6.3-stable_win64_console.exe"
$Proj = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Out = $PSScriptRoot

if ($Mode -eq "online") { $HostMode = "online-host"; $ClientMode = "online-client" }
else { $HostMode = "host"; $ClientMode = "client" }

$hostLog = Join-Path $Out "_net_smoke_host.log"
$cliLog  = Join-Path $Out "_net_smoke_client.log"
Remove-Item $hostLog, $cliLog -ErrorAction SilentlyContinue

Write-Host "=== Spell Bop net smoke ($Mode) ===" -ForegroundColor Cyan

# 1. Import ONCE (single instance) so the two game runs never contend on .godot/.
# Start-Process (not the call operator) so native stderr warnings aren't wrapped
# into terminating errors by PowerShell 5.1.
Write-Host "Importing project (once)..."
# Use -WorkingDirectory + "--path ." so the spaced project path never goes through
# the arg array (Start-Process splits array elements on spaces).
Start-Process -FilePath $Godot -ArgumentList @("--headless", "--path", ".", "--import") -WorkingDirectory $Proj `
    -RedirectStandardOutput (Join-Path $Out "_net_smoke_import.log") `
    -RedirectStandardError (Join-Path $Out "_net_smoke_import.err") -Wait | Out-Null

# 2. Launch host, give its server a moment, then the client.
function Launch($mode, $log, $pos) {
    $base = @("--path", ".")
    if ($Headless) { $base += "--headless" } else { $base += @("--position", $pos) }
    $base += @("--", "--net-smoke=$mode")
    return Start-Process -FilePath $Godot -ArgumentList $base -WorkingDirectory $Proj `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru
}

Write-Host "Launching HOST ($HostMode)..."
$hostProc = Launch $HostMode $hostLog "60,60"
Start-Sleep -Seconds 2   # let the host's ENet server / Nakama match come up first
Write-Host "Launching CLIENT ($ClientMode)..."
$cliProc = Launch $ClientMode $cliLog "640,60"

# 3. Poll both logs for the OK marker.
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$hostOK = $false; $cliOK = $false
while ((Get-Date) -lt $deadline -and -not ($hostOK -and $cliOK)) {
    Start-Sleep -Milliseconds 500
    if (Test-Path $hostLog) { $hostOK = (Select-String -Path $hostLog -Pattern "\[NET-SMOKE\] OK" -Quiet) }
    if (Test-Path $cliLog)  { $cliOK  = (Select-String -Path $cliLog  -Pattern "\[NET-SMOKE\] OK" -Quiet) }
}

# 4. Tear down the windows.
foreach ($p in @($hostProc, $cliProc)) {
    if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
}

# 5. Report.
function Fp($log) {
    if (-not (Test-Path $log)) { return "<no log>" }
    $m = Select-String -Path $log -Pattern "\[NET-SMOKE\] tick=\d+ fp=(.*)$"
    if ($m) { return $m.Matches[-1].Groups[1].Value.Trim() } else { return "<no fingerprint>" }
}
$hostFp = Fp $hostLog; $cliFp = Fp $cliLog
Write-Host ""
Write-Host "HOST   reached OK: $hostOK   fp: $hostFp"
Write-Host "CLIENT reached OK: $cliOK   fp: $cliFp"

if ($hostOK -and $cliOK -and $hostFp -eq $cliFp -and $hostFp -ne "<no fingerprint>") {
    Write-Host "RESULT: PASS - both instances synced; fingerprints match." -ForegroundColor Green
    exit 0
} else {
    Write-Host "RESULT: FAIL - see _net_smoke_host.log / _net_smoke_client.log (+ .err)." -ForegroundColor Red
    Write-Host "  (Sync markers: [NET-SMOKE] sync_started should appear in BOTH logs.)"
    exit 1
}
