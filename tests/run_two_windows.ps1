# run_two_windows.ps1 - Manual two-window LAN playtest launcher (one keyboard, two wizards).
#
# Launches TWO local game WINDOWS for a hands-on LAN netplay playtest on a SINGLE
# machine. Both windows are passed `-- --local-split`, which makes PlayerController use
# the per-role keyboard split so one keyboard drives both wizards unambiguously:
#   * LEFT  window -> HOST   -> move with  A / D
#   * RIGHT window -> CLIENT -> move with the LEFT / RIGHT arrow keys
# Cast = Space, cards = 8 / 9 / 0 in BOTH windows.
#
# This is the MANUAL counterpart to run_net_smoke.ps1 (which AUTO-drives + verifies and
# does NOT need --local-split because neither wizard moves). Here YOU drive:
#   * LEFT window:  QuickMatch -> Local -> Host
#   * RIGHT window: QuickMatch -> Local -> Search   (discovers the host on 127.0.0.1)
# then play - left wizard on A/D, right wizard on the arrows.
#
# WHY --local-split is opt-in: on real SEPARATE devices each peer reads the DEFAULT move
# actions (touch joystick + A/D + arrows all feed move_left/move_right), so touch movement
# works online. The A/D-vs-arrows split is ONLY for two windows sharing one keyboard.
# Do NOT pass --local-split to a real online / mobile build - it would strand touch movement.
#
# Usage:  pwsh tests/run_two_windows.ps1
#
# Two-instance import lock (bug graveyard): two Godot processes importing the same project
# at once deadlock on .godot/. We import ONCE up front, then launch the two game windows
# (no import), so they never contend.

$ErrorActionPreference = "Continue"   # Godot writes harmless GDExtension warnings to stderr
# Godot 4.6.3-stable (Creative Director mandate - 4.6.1 has GDExtension regressions vs delta_rollback).
$Godot = "C:/Users/laure/Downloads/Godot_v4.6.3-stable_win64.exe/Godot_v4.6.3-stable_win64_console.exe"
$Proj = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

Write-Host "=== Spell Bop two-window LAN playtest (--local-split) ===" -ForegroundColor Cyan
Write-Host "  LEFT = HOST  (move A / D)        RIGHT = CLIENT (move LEFT / RIGHT arrows)" -ForegroundColor DarkGray
Write-Host "  LEFT:  QuickMatch > Local > Host    RIGHT: QuickMatch > Local > Search" -ForegroundColor DarkGray

# 1. Import ONCE (single instance) so the two game windows never contend on .godot/.
#    Start-Process + "--path ." (not a spaced path in the arg array) per the launcher rules.
Write-Host "Importing project (once)..."
Start-Process -FilePath $Godot -ArgumentList @("--headless", "--path", ".", "--import") -WorkingDirectory $Proj `
    -RedirectStandardOutput (Join-Path $PSScriptRoot "_two_windows_import.log") `
    -RedirectStandardError (Join-Path $PSScriptRoot "_two_windows_import.err") -Wait | Out-Null

# 2. Launch the two windows, BOTH with --local-split (after the `--` user-args separator).
function Launch($pos) {
    return Start-Process -FilePath $Godot `
        -ArgumentList @("--path", ".", "--position", $pos, "--", "--local-split") `
        -WorkingDirectory $Proj -PassThru
}
Write-Host "Launching LEFT (host) window..."
Launch "60,60" | Out-Null
Start-Sleep -Seconds 1
Write-Host "Launching RIGHT (client) window..."
Launch "640,60" | Out-Null

Write-Host "Both windows launched. Host on the LEFT, Search on the RIGHT, then play." -ForegroundColor Green
Write-Host "Close the windows when done." -ForegroundColor DarkGray
