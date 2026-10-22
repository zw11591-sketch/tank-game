# LAN probe runner: start the host process, then the client, and print both sides.
#
#   powershell -ExecutionPolicy Bypass -File tools\net_probe.ps1
#   powershell -ExecutionPolicy Bypass -File tools\net_probe.ps1 -Port 46000
#
# Exit code is 0 only when both sides report PROBE ... OK. Full output stays in
# tools\_probe_<port>_host.txt and tools\_probe_<port>_client.txt.
param(
    [int]$Port = 45988,
    [string]$Godot = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Godot)) {
    if ($env:GODOT) { $Godot = $env:GODOT } else { $Godot = "godot" }
}

# Output names are port-scoped: two probe runs on different ports can share one
# machine (and one workspace) without overwriting each other's logs, which used
# to look exactly like a networking failure.
$hostOut = Join-Path $root "tools\_probe_${Port}_host.txt"
$hostErr = Join-Path $root "tools\_probe_${Port}_host_err.txt"
$clientOut = Join-Path $root "tools\_probe_${Port}_client.txt"
$clientErr = Join-Path $root "tools\_probe_${Port}_client_err.txt"
$scene = "res://tools/NetProbe.tscn"

$hostArgs = @("--headless", "--path", $root, $scene, "--", "--role=host", "--port=$Port")
$clientArgs = @("--headless", "--path", $root, $scene, "--", "--role=client", "--port=$Port")

Write-Host "starting host on port $Port ..."
$hostProc = Start-Process -FilePath $Godot -ArgumentList $hostArgs `
    -RedirectStandardOutput $hostOut -RedirectStandardError $hostErr `
    -PassThru -NoNewWindow

# Give the host time to load assets and start listening. The client also waits
# for its own asset load before joining.
Start-Sleep -Seconds 3

Write-Host "starting client ..."
$clientProc = Start-Process -FilePath $Godot -ArgumentList $clientArgs `
    -RedirectStandardOutput $clientOut -RedirectStandardError $clientErr `
    -PassThru -NoNewWindow

$clientProc.WaitForExit(180000) | Out-Null
$hostProc.WaitForExit(180000) | Out-Null
# 脚本解析失败时探针不会自己退出，进程会一直挂着：这里兜底收尸，
# 否则调用方（CI / 人手一条命令）会无限等下去。
foreach ($p in @($clientProc, $hostProc)) {
    if (-not $p.HasExited) {
        try { $p.Kill() } catch { }
        Write-Host "WARNING: $($p.Id) 超时未退出，已强制结束"
    }
}

Write-Host ""
Write-Host "===== CLIENT ====="
Get-Content $clientOut
if ((Get-Item $clientErr).Length -gt 0) { Get-Content $clientErr }
Write-Host ""
Write-Host "===== HOST ====="
Get-Content $hostOut
if ((Get-Item $hostErr).Length -gt 0) { Get-Content $hostErr }

$hostOk = Select-String -Path $hostOut -Pattern "PROBE HOST OK" -Quiet
$clientOk = Select-String -Path $clientOut -Pattern "PROBE CLIENT OK" -Quiet
if ($hostOk -and $clientOk) {
    Write-Host ""
    Write-Host "PROBE ALL PASS"
    exit 0
}
Write-Host ""
Write-Host "PROBE FAILED"
exit 1

