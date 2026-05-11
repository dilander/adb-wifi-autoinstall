Set-Location -LiteralPath $PSScriptRoot

$pidFile = 'logcat_pids.txt'
if (-not (Test-Path $pidFile)) {
    Write-Host "No active logcat session found (logcat_pids.txt missing)."
    Write-Host "If adb processes are stuck, use: taskkill /IM adb.exe /F"
    exit 0
}

$procIds = @(Get-Content $pidFile | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })

if ($procIds.Count -eq 0) {
    Write-Host "PID file is empty."
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    exit 0
}

Write-Host "Stopping $($procIds.Count) logcat session(s) gracefully..."

foreach ($procId in $procIds) {
    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -eq 'cmd') {
        & taskkill /PID $procId 2>$null | Out-Null
    }
}

$deadline = (Get-Date).AddSeconds(5)
while ((Get-Date) -lt $deadline) {
    $alive = $procIds | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }
    if (-not $alive) { break }
    Start-Sleep -Milliseconds 200
}

foreach ($procId in $procIds) {
    if (Get-Process -Id $procId -ErrorAction SilentlyContinue) {
        Write-Warning "PID $procId did not exit within 5s, force-killing (log may be truncated)."
        & taskkill /PID $procId /F 2>$null | Out-Null
    }
}

Remove-Item $pidFile -Force -ErrorAction SilentlyContinue

Write-Host "Done. Check Logs\ for output."
