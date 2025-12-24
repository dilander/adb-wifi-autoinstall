#requires -version 5.1
<#
adb-wifi-autoinstall.ps1

機能:
- ADB Wi-Fi 接続監視(切断時に自動復旧)
  - USBが刺さっていれば adb tcpip 5555 を叩いて復旧可能
  - USBが無ければ adb connect のみ(端末側待受が無いと復旧不可)
- カレントディレクトリ(=WatchDir)の APK 更新監視
  - 起動時に「最新APK」を記憶
  - APKが更新されたら自動で adb install
  - FileSystemWatcher取りこぼし対策としてポーリングでも検知
- ログ削減:
  - 接続OKは「同じ1行を更新」表示
  - 重要イベント時のみ改行して通常ログ

前提:
- 端末はUSBデバッグ有効
- 最初にUSBで接続できる(IP取得とtcpip有効化のため)
#>

param(
  [int]$Port = 5555,
  [int]$IntervalSec = 5,
  [string]$WatchDir = (Get-Location).Path,
  [string]$ApkFilter = "*.apk",
  [int]$DebounceMs = 1200,
  [int]$PollApkEverySec = 5
)

# ---- 文字化け対策(PowerShell側の出力をUTF-8に寄せる) ----
try {
  [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
  $OutputEncoding = [Console]::OutputEncoding
} catch { }

# ---- Windows標準サウンド(1回だけロード) ----
try { Add-Type -AssemblyName System.Windows.Forms } catch { }

# ---------- 1行ステータス表示(同じ行を上書き) ----------
$script:StatusLineLen = 0
$script:ConnectedSince = $null

function Write-StatusLine {
  param([string]$Text)

  $pad = ""
  if ($script:StatusLineLen -gt $Text.Length) {
    $pad = " " * ($script:StatusLineLen - $Text.Length)
  }
  $script:StatusLineLen = $Text.Length

  Write-Host -NoNewline ("`r" + $Text + $pad)
}

function Flush-StatusLine {
  if ($script:StatusLineLen -gt 0) {
    Write-Host ""  # 改行
    $script:StatusLineLen = 0
  }
}

# --- 共通ログラッパー ---
function Write-Log {
  param([string]$Text)
  $now = Get-Date -Format "HH:mm:ss"
  Flush-StatusLine
  Write-Host "[$now] $Text"
}

# ADB存在チェック（警告のみ、挙動変更なし）
function Check-AdbExists {
  try {
    & adb version > $null 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Log "警告: adb の実行に失敗しました。PATHを確認してください。" }
  } catch {
    Write-Log "警告: adb が見つかりません。PATHを確認してください。"
  }
}

# ---------- ADB helpers ----------
function Get-UsbDeviceSerial {
  $lines = & adb devices 2>$null
  foreach ($line in $lines) {
    if ($line -match '^List of devices attached') { continue }
    if ($line -match '^\s*$') { continue }
    $parts = $line -split '\s+'
    if ($parts.Count -ge 2 -and $parts[1] -eq 'device') {
      $id = $parts[0]
      if ($id -notmatch ':\d+$') { return $id }  # USB端末っぽい
    }
  }
  return $null
}

function Get-PhoneIpFromUsb {
  param([string]$Serial)
  $out = & adb -s $Serial shell ip route 2>$null
  foreach ($line in $out) {
    if ($line -match '\bsrc\s+(\d+\.\d+\.\d+\.\d+)\b') { return $Matches[1] }
  }
  return $null
}

function Ensure-TcpipEnabled {
  param([string]$Serial, [int]$Port)
  & adb -s $Serial tcpip $Port 2>&1
}

function Test-AdbConnected {
  param([string]$Target)
  $out = & adb devices 2>$null
  foreach ($line in $out) {
    if ($line -match ("^{0}\s+device$" -f [regex]::Escape($Target))) { return $true }
  }
  return $false
}

function Connect-Adb {
  param([string]$Target)
  & adb connect $Target 2>&1
}

function Ensure-Connected {
  param([string]$Target, [int]$Port)

  if (Test-AdbConnected -Target $Target) { return $true }

  Flush-StatusLine
  Write-Log "切断検知 -> 復旧処理: $Target"

  $serial = Get-UsbDeviceSerial
  if ($serial) {
    Write-Log "USBあり: tcpip 有効化 -> connect"
    Ensure-TcpipEnabled -Serial $serial -Port $Port | ForEach-Object { if($_){ Write-Log "  $_" } }
  } else {
    Write-Log "USBなし: connect のみ(端末側待受が無いと復旧不可)"
  }

  Connect-Adb -Target $Target | ForEach-Object { if($_){ Write-Log "  $_" } }
  return (Test-AdbConnected -Target $Target)
}

# ---------- APK helpers ----------
function Get-LatestApk {
  param([string]$Dir, [string]$Filter)
  Get-ChildItem -Path $Dir -Filter $Filter -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc, FullName |
    Select-Object -Last 1
}

function Get-ApkSignature {
  param($FileInfo)
  if (-not $FileInfo) { return "" }
  return "$($FileInfo.FullName)|$($FileInfo.LastWriteTimeUtc.Ticks)|$($FileInfo.Length)"
}

function Wait-ForFileReady {
  param([string]$Path, [int]$TimeoutSec = 60)

  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    try {
      $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
      $fs.Close()
      return $true
    } catch {
      Start-Sleep -Milliseconds 200
    }
  }
  return $false
}

function Install-Apk {
  param(
    [string]$ApkPath,
    [string]$Target,
    [int]$Port
  )

  $now = Get-Date -Format "HH:mm:ss"
  Flush-StatusLine

  if (-not (Test-Path $ApkPath)) {
    Write-Log "APKが見つかりません: $ApkPath"
    return
  }

  if (-not (Wait-ForFileReady -Path $ApkPath -TimeoutSec 60)) {
    Write-Log "APKが書き込み中っぽいので install を中断: $ApkPath"
    return
  }

  if (-not (Ensure-Connected -Target $Target -Port $Port)) {
    Write-Log "端末未接続のため install をスキップ(次回更新検知で再試行)"
    return
  }

  Write-Log "APKインストール開始: $ApkPath"

  # 安定化: Wi-Fi ADBでstreaming失敗しやすいので --no-streaming
  # Unityのdevelopment build等で testOnly になることがあるので -t
  & adb -s $Target install -r -t --no-streaming -- "$ApkPath" 2>&1 |
    ForEach-Object { if($_){ Write-Log "  $_" } }

  $exit = $LASTEXITCODE

  # Windows標準サウンドで通知
  try {
    if ($exit -eq 0) {
      Write-Log "APKインストール成功($exit)"
      [System.Media.SystemSounds]::Asterisk.Play()
    } else {
      Write-Log "APKインストール失敗($exit)"
      [System.Media.SystemSounds]::Hand.Play()
    }
  } catch { }
}

# ---------- main ----------
Write-Host "======================================"
Write-Host " ADB Wi-Fi Auto Install"
Write-Host " WatchDir: $WatchDir"
Write-Host " Filter  : $ApkFilter"
Write-Host " Interval: ${IntervalSec}s / Port: $Port"
Write-Host " 停止: Ctrl + C"
Write-Host "======================================"

# ADB 存在チェック（警告を出す）
Check-AdbExists

# 接続先(target)確定:USBからIP取得
$target = $null
while (-not $target) {
  $serial = Get-UsbDeviceSerial
  if ($serial) {
    $ip = Get-PhoneIpFromUsb -Serial $serial
    if ($ip) {
      $target = "$ip`:$Port"
      Write-Log "接続先確定: $target (USB: $serial / IP: $ip)"
      break
    }
  }
  Write-Log "USBからIP取得できないので待機中…(USB接続+デバッグ許可を確認)"
  Start-Sleep -Seconds 2
}

# 起動時:最新APKを記憶
$latest = Get-LatestApk -Dir $WatchDir -Filter $ApkFilter
$script:KnownApkSig = Get-ApkSignature -FileInfo $latest
if ($latest) {
  Write-Log "起動時の最新APK: $([System.IO.Path]::GetFileName($latest.FullName)) ($($latest.LastWriteTimeUtc.ToLocalTime().ToString([System.Globalization.CultureInfo]::CurrentCulture)) / $($latest.Length) bytes)"
} else {
  Write-Log "APKがまだありません(監視は継続)"
}

# debounce用タイマー(イベント連打をまとめる)
$timer = New-Object System.Timers.Timer
$timer.Interval = $DebounceMs
$timer.AutoReset = $false

# 監視イベント(Created/Changed/Renamed)の共通Action:debounce
$action = {
  try {
    $t = $using:timer
    $t.Stop()
    $t.Start()
  } catch { }
}

# タイマーElapsed:最新APKを見直して署名が変わっていればinstall
Register-ObjectEvent -InputObject $timer -EventName Elapsed -Action {
  $latest = Get-LatestApk -Dir $using:WatchDir -Filter $using:ApkFilter
  if (-not $latest) { return }

  $sig = Get-ApkSignature -FileInfo $latest
  if ($sig -ne $script:KnownApkSig) {
    $script:KnownApkSig = $sig
    Write-Log "APK更新検知(event): $([System.IO.Path]::GetFileName($latest.FullName)) ($($latest.LastWriteTimeUtc.ToLocalTime().ToString([System.Globalization.CultureInfo]::CurrentCulture)) / $($latest.Length) bytes)"
    Install-Apk -ApkPath $latest.FullName -Target $using:target -Port $using:Port
  }
} | Out-Null

# FileSystemWatcher
$fsw = New-Object System.IO.FileSystemWatcher
$fsw.Path = $WatchDir
$fsw.Filter = $ApkFilter
$fsw.IncludeSubdirectories = $false
$fsw.NotifyFilter = [System.IO.NotifyFilters]'FileName, LastWrite, Size, CreationTime'

Register-ObjectEvent $fsw Created -Action $action | Out-Null
Register-ObjectEvent $fsw Changed -Action $action | Out-Null
Register-ObjectEvent $fsw Renamed -Action $action | Out-Null
$fsw.EnableRaisingEvents = $true

# ポーリング用(イベント取りこぼし対策)
$swPoll = [Diagnostics.Stopwatch]::StartNew()

while ($true) {
  $now = Get-Date -Format "HH:mm:ss"

  # 1) ADB watchdog(接続OKは1行更新)
  try {
    if (Test-AdbConnected -Target $target) {
      if ($script:ConnectedSince -eq $null) { $script:ConnectedSince = $now }
      Write-StatusLine ("[{0}] 接続OK: {1} (last update: {2})" -f $script:ConnectedSince, $target, $now)
    } else {
      $script:ConnectedSince = $null
      Ensure-Connected -Target $target -Port $Port | Out-Null
    }
  } catch {
    Write-Log "adb 実行エラー: $($_.Exception.Message)"
  }

  # 2) APKポーリング(保険):一定間隔で最新APKの署名を見直す
  if ($swPoll.Elapsed.TotalSeconds -ge $PollApkEverySec) {
    $swPoll.Restart()
    try {
      $latest = Get-LatestApk -Dir $WatchDir -Filter $ApkFilter
      if ($latest) {
        $sig = Get-ApkSignature -FileInfo $latest
        if ($sig -ne $script:KnownApkSig) {
          $script:KnownApkSig = $sig
          Write-Log "APK更新検知(polling): $([System.IO.Path]::GetFileName($latest.FullName)) ($($latest.LastWriteTimeUtc.ToLocalTime().ToString([System.Globalization.CultureInfo]::CurrentCulture)) / $($latest.Length) bytes)"
          Install-Apk -ApkPath $latest.FullName -Target $target -Port $Port
        }
      }
    } catch {
      Write-Log "APKポーリング中のエラー: $($_.Exception.Message)"
    }
  }

  Start-Sleep -Seconds $IntervalSec
}
