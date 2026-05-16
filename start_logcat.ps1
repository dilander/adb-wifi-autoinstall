$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

if (-not (Test-Path 'Logs')) {
    New-Item -ItemType Directory -Path 'Logs' | Out-Null
}

$pidFile = 'logcat_pids.txt'

# Block double-start
if (Test-Path $pidFile) {
    $existing = Get-Content $pidFile | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
    $alive = $existing | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }
    if ($alive) {
        Write-Host "A logcat session is already running (PIDs: $($alive -join ','))."
        Write-Host "Press Ctrl+C in the existing session, or run stop_logcat.bat first."
        exit 1
    }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}

function Resolve-Nickname {
    param([string]$serial)
    $nickname = $serial
    if (Test-Path 'device_nicknames.txt') {
        foreach ($line in Get-Content 'device_nicknames.txt') {
            $t = $line.Trim()
            if (-not $t -or $t.StartsWith('#')) { continue }
            $parts = $line -split '=', 2
            if ($parts.Count -eq 2 -and $parts[0].Trim() -eq $serial) {
                $nickname = $parts[1].Trim()
                break
            }
        }
    }
    $nickname = $nickname -replace '[()]', ''
    $nickname = $nickname -replace '\s', '_'
    $nickname = $nickname -replace ':', '_'
    return $nickname
}

# Enumerate connected devices
$devices = @()
foreach ($line in (adb devices | Select-Object -Skip 1)) {
    if ($line -match '^(\S+)\s+device\s*$') {
        $devices += $matches[1]
    }
}

if ($devices.Count -eq 0) {
    Write-Host "No devices connected."
    exit 1
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

Write-Host "Starting logcat for $($devices.Count) device(s) (hidden)..."
Write-Host ""

$started = @()
foreach ($serial in $devices) {
    $nickname = Resolve-Nickname $serial
    $logFile = Join-Path 'Logs' "${nickname}_unity_${timestamp}.log"

    & adb -s $serial logcat -c 2>$null | Out-Null

    $cmdLine = "adb -s `"$serial`" logcat -v threadtime -s Unity > `"$logFile`""
    $proc = Start-Process -FilePath 'cmd.exe' `
        -ArgumentList '/c', $cmdLine `
        -WindowStyle Hidden `
        -PassThru

    $started += [PSCustomObject]@{
        Pid      = $proc.Id
        Serial   = $serial
        Nickname = $nickname
        LogFile  = $logFile
    }
    "$($proc.Id)" | Add-Content $pidFile
    Write-Host "  [$nickname] pid=$($proc.Id)  ->  $logFile"
}

Write-Host ""
Write-Host "Recording. Press Ctrl+C to stop and flush."
Write-Host ""

function Stop-Sessions {
    Write-Host ""
    Write-Host "Stopping gracefully..."

    foreach ($s in $started) {
        if (Get-Process -Id $s.Pid -ErrorAction SilentlyContinue) {
            # taskkill without /F -> WM_CLOSE -> CTRL_CLOSE_EVENT -> CRT stdio flush
            & taskkill /PID $s.Pid 2>$null | Out-Null
        }
    }

    # Wait up to 5s for graceful exit (required for buffer flush)
    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline) {
        $alive = $started | Where-Object { Get-Process -Id $_.Pid -ErrorAction SilentlyContinue }
        if (-not $alive) { break }
        Start-Sleep -Milliseconds 200
    }

    foreach ($s in $started) {
        if (Get-Process -Id $s.Pid -ErrorAction SilentlyContinue) {
            Write-Warning "PID $($s.Pid) did not exit within 5s, force-killing (log may be truncated)."
            & taskkill /PID $s.Pid /F 2>$null | Out-Null
        }
    }

    if (Test-Path $pidFile) {
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }

    Write-Host ""
    Write-Host "Results:"
    foreach ($s in $started) {
        if (Test-Path $s.LogFile) {
            $size = (Get-Item $s.LogFile).Length
            Write-Host ("  {0}  {1} bytes" -f $s.LogFile, $size)
        } else {
            Write-Host "  $($s.LogFile)  (missing)"
        }
    }
}

try {
    while ($true) {
        Start-Sleep -Seconds 1
    }
} finally {
    Stop-Sessions
}
