#requires -version 5.1
<#
adb-wifi-autoinstall.ps1

機能:
- ADB Wi-Fi 接続監視(切断時に自動復旧) ※複数端末対応
  - USBが刺さっていれば adb tcpip 5555 を叩いて復旧可能
  - USBが無ければ adb connect のみ(端末側待受が無いと復旧不可)
- カレントディレクトリ(=WatchDir)の APK 更新監視
  - 起動時に「最新APK」を記憶
  - APKが更新されたら全ターゲットに並列で adb install
  - FileSystemWatcher取りこぼし対策としてポーリングでも検知
- 複数Android端末対応:
  - USB接続された全端末から自動でIPを収集してターゲット化
  - 実行中に新規USB接続された端末も動的に対象へ追加
  - APKインストールは全ターゲットに並列実行(ThreadJobがあれば使用、無ければStart-Jobにフォールバック)
- ログ削減:
  - 接続OKは「台数 接続OK: N/M 台」のサマリを1行更新
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

# USB接続されている全端末のシリアルを返す(Wi-Fi接続分は除外)
function Get-UsbDeviceSerials {
  $serials = @()
  $lines = & adb devices 2>$null
  foreach ($line in $lines) {
    if ($line -match '^List of devices attached') { continue }
    if ($line -match '^\s*$') { continue }
    $parts = $line -split '\s+'
    if ($parts.Count -ge 2 -and $parts[1] -eq 'device') {
      $id = $parts[0]
      if ($id -notmatch ':\d+$') { $serials += $id }  # USB端末っぽい
    }
  }
  return ,$serials
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

# 指定USBシリアルが現在USB接続されているか
function Test-UsbSerialConnected {
  param([string]$Serial)
  if (-not $Serial) { return $false }
  $current = Get-UsbDeviceSerials
  return ($current -contains $Serial)
}

# 単一ターゲットの接続確認・復旧
function Ensure-ConnectedSingle {
  param([string]$Target, [int]$Port)

  if (Test-AdbConnected -Target $Target) { return $true }

  Flush-StatusLine
  Write-Log "切断検知 -> 復旧処理: $Target"

  $serial = $null
  if ($script:Targets.ContainsKey($Target)) {
    $serial = $script:Targets[$Target].Serial
  }

  if ($serial -and (Test-UsbSerialConnected -Serial $serial)) {
    Write-Log "  USBあり(serial=$serial): tcpip 再有効化"
    Ensure-TcpipEnabled -Serial $serial -Port $Port | ForEach-Object { if($_){ Write-Log "    $_" } }
    Start-Sleep -Milliseconds 500
  } else {
    Write-Log "  USBなし: connect のみ(端末側待受が無いと復旧不可)"
  }

  Connect-Adb -Target $Target | ForEach-Object { if($_){ Write-Log "  $_" } }
  return (Test-AdbConnected -Target $Target)
}

# USB接続中の全端末を走査し、未知ならtcpip有効化+connectしてターゲット一覧に追加
# 返り値: 今回追加されたターゲット数
function Refresh-Targets {
  param([int]$Port)

  $serials = Get-UsbDeviceSerials
  $added = 0
  foreach ($serial in $serials) {
    # 既に同serialを知っているターゲットがあるか
    $alreadyKnown = $false
    foreach ($k in @($script:Targets.Keys)) {
      if ($script:Targets[$k].Serial -eq $serial) { $alreadyKnown = $true; break }
    }
    if ($alreadyKnown) { continue }

    $ip = Get-PhoneIpFromUsb -Serial $serial
    if (-not $ip) {
      Write-Log "IP取得失敗: serial=$serial (Wi-Fi未接続の可能性)"
      continue
    }
    $target = "${ip}:${Port}"
    if ($script:Targets.ContainsKey($target)) {
      Write-Log "警告: 既知ターゲット $target に serial=$serial が衝突"
      continue
    }

    Write-Log "新規端末検出: serial=$serial / IP=$ip -> tcpip $Port 有効化"
    Ensure-TcpipEnabled -Serial $serial -Port $Port | ForEach-Object { if($_){ Write-Log "  $_" } }
    Start-Sleep -Milliseconds 500
    Connect-Adb -Target $target | ForEach-Object { if($_){ Write-Log "  $_" } }

    $script:Targets[$target] = @{ Serial = $serial; AddedAt = Get-Date }
    Write-Log "ターゲット追加: $target (serial=$serial) / 合計 $($script:Targets.Count) 台"
    $added++
  }
  return $added
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

# 複数ターゲットへの並列インストール
function Install-ApkParallel {
  param(
    [string]$ApkPath,
    [string[]]$Targets,
    [int]$Port
  )

  Flush-StatusLine

  if (-not (Test-Path $ApkPath)) {
    Write-Log "APKが見つかりません: $ApkPath"
    return
  }
  if (-not (Wait-ForFileReady -Path $ApkPath -TimeoutSec 60)) {
    Write-Log "APKが書き込み中っぽいので install を中断: $ApkPath"
    return
  }
  if (-not $Targets -or $Targets.Count -eq 0) {
    Write-Log "接続中のターゲットがないため install をスキップ(次回更新検知で再試行)"
    return
  }

  $engine = if ($script:UseThreadJob) { 'ThreadJob' } else { 'Start-Job' }
  Write-Log "APK並列インストール開始 ($($Targets.Count)台 / $engine): $ApkPath"

  $jobs = @()
  foreach ($t in $Targets) {
    # 並列install時、`adb install --no-streaming` は内部で `/data/local/tmp/<apkname>`
    # という固定名で push するため、複数端末に同じローカルAPKを並列投入すると
    # リモート一時ファイル名が衝突して一方のinstallが失敗する。
    # 回避策として push -> pm install -> rm を自前で行い、リモート名を端末ごとに
    # ユニーク化する。
    $sb = {
      param($Target, $Apk)

      $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Apk)
      $uniqueId = [Guid]::NewGuid().ToString('N').Substring(0, 8)
      $remotePath = "/data/local/tmp/installtmp_${baseName}_${uniqueId}.apk"

      $out = @()

      # 1) push
      $pushOut = & adb -s $Target push "$Apk" $remotePath 2>&1
      $pushExit = $LASTEXITCODE
      foreach ($l in $pushOut) { if ($l) { $out += "[push] $l" } }
      if ($pushExit -ne 0) {
        return [PSCustomObject]@{ Target = $Target; Success = $false; Output = $out; Stage = 'push' }
      }

      # 2) pm install (-r: 再インストール, -t: testOnly許可)
      # `adb shell pm install` は exit code が 0 になりがちなので出力で Success 判定する
      $installOut = & adb -s $Target shell pm install -r -t "$remotePath" 2>&1
      foreach ($l in $installOut) { if ($l) { $out += "[install] $l" } }
      $installSuccess = $false
      foreach ($l in $installOut) { if ($l -match '^Success') { $installSuccess = $true; break } }

      # 3) rm (後片付け)
      $rmOut = & adb -s $Target shell rm -f "$remotePath" 2>&1
      foreach ($l in $rmOut) { if ($l) { $out += "[rm] $l" } }

      [PSCustomObject]@{ Target = $Target; Success = $installSuccess; Output = $out; Stage = 'install' }
    }
    if ($script:UseThreadJob) {
      $jobs += Start-ThreadJob -ScriptBlock $sb -ArgumentList $t, $ApkPath
    } else {
      $jobs += Start-Job -ScriptBlock $sb -ArgumentList $t, $ApkPath
    }
  }

  $results = $jobs | Wait-Job | Receive-Job
  $jobs | Remove-Job -Force -ErrorAction SilentlyContinue

  $success = 0
  $fail = 0
  foreach ($r in $results) {
    foreach ($line in $r.Output) { if ($line) { Write-Log "  [$($r.Target)] $line" } }
    if ($r.Success) {
      Write-Log "[$($r.Target)] APKインストール成功"
      $success++
    } else {
      Write-Log "[$($r.Target)] APKインストール失敗(stage=$($r.Stage))"
      $fail++
    }
  }

  Write-Log "並列インストール結果: 成功=$success / 失敗=$fail / 合計=$($Targets.Count)"

  try {
    if ($fail -eq 0) {
      [System.Media.SystemSounds]::Asterisk.Play()
    } else {
      [System.Media.SystemSounds]::Hand.Play()
    }
  } catch { }
}

# ---------- main ----------
Write-Host "======================================"
Write-Host " ADB Wi-Fi Auto Install (multi-device)"
Write-Host " WatchDir: $WatchDir"
Write-Host " Filter  : $ApkFilter"
Write-Host " Interval: ${IntervalSec}s / Port: $Port"
Write-Host " 停止: Ctrl + C"
Write-Host "======================================"

# ADB 存在チェック（警告を出す）
Check-AdbExists

# 並列実行エンジン選択: ThreadJobがあれば使う、無ければStart-Job
try { Import-Module ThreadJob -ErrorAction SilentlyContinue } catch { }
$script:UseThreadJob = [bool](Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)
if ($script:UseThreadJob) {
  Write-Log "並列実行エンジン: ThreadJob 使用"
} else {
  Write-Log "並列実行エンジン: Start-Job 使用 (ThreadJob 未検出)"
}

# ターゲット管理 (key: "ip:port", value: @{Serial; AddedAt})
$script:Targets = @{}
$script:ForcePollNow = $false

# 接続先(target)確定: 最低1台見つかるまで待機
while ($script:Targets.Count -eq 0) {
  Refresh-Targets -Port $Port | Out-Null
  if ($script:Targets.Count -eq 0) {
    Write-Log "USB接続されてIPが取れる端末がありません。待機中…(USB接続+デバッグ許可+Wi-Fi接続を確認)"
    Start-Sleep -Seconds 2
  }
}
Write-Log "初期ターゲット: $($script:Targets.Count) 台 ($((($script:Targets.Keys) | Sort-Object) -join ', '))"

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

# タイマーElapsed: 次回のメインループでAPKチェックを強制する
# (実際のsig比較とinstallはメインループ側で実施 ― race condition回避のため)
Register-ObjectEvent -InputObject $timer -EventName Elapsed -Action {
  $script:ForcePollNow = $true
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

  # 0) 動的ターゲット追加: USB新規接続の検出
  try {
    Refresh-Targets -Port $Port | Out-Null
  } catch {
    Write-Log "Refresh-Targets エラー: $($_.Exception.Message)"
  }

  # 1) 各ターゲットの接続チェック + 切断時の復旧試行
  $okCount = 0
  $total = $script:Targets.Count
  foreach ($t in @($script:Targets.Keys)) {
    try {
      if (Test-AdbConnected -Target $t) {
        $okCount++
      } else {
        Ensure-ConnectedSingle -Target $t -Port $Port | Out-Null
      }
    } catch {
      Write-Log "adb チェックエラー($t): $($_.Exception.Message)"
    }
  }

  # ステータス1行更新
  if ($total -gt 0 -and $okCount -eq $total) {
    if ($null -eq $script:ConnectedSince) { $script:ConnectedSince = $now }
    $since = $script:ConnectedSince
    Write-StatusLine ("[{0}] 接続OK: {1}/{2} 台 (last update: {3})" -f $since, $okCount, $total, $now)
  } else {
    $script:ConnectedSince = $null
    Write-StatusLine ("[{0}] 接続OK: {1}/{2} 台 (last update: {0})" -f $now, $okCount, $total)
  }

  # 2) APKチェック(FSWイベント or 定期ポーリング)
  $shouldCheck = $script:ForcePollNow -or ($swPoll.Elapsed.TotalSeconds -ge $PollApkEverySec)
  if ($shouldCheck) {
    $source = if ($script:ForcePollNow) { 'event' } else { 'polling' }
    $script:ForcePollNow = $false
    $swPoll.Restart()
    try {
      $latest = Get-LatestApk -Dir $WatchDir -Filter $ApkFilter
      if ($latest) {
        $sig = Get-ApkSignature -FileInfo $latest
        if ($sig -ne $script:KnownApkSig) {
          $script:KnownApkSig = $sig
          Write-Log "APK更新検知($source): $([System.IO.Path]::GetFileName($latest.FullName)) ($($latest.LastWriteTimeUtc.ToLocalTime().ToString([System.Globalization.CultureInfo]::CurrentCulture)) / $($latest.Length) bytes)"

          # 接続OKなターゲットだけに並列install
          $aliveTargets = @()
          foreach ($t in @($script:Targets.Keys)) {
            if (Test-AdbConnected -Target $t) { $aliveTargets += $t }
          }
          Install-ApkParallel -ApkPath $latest.FullName -Targets $aliveTargets -Port $Port
        }
      }
    } catch {
      Write-Log "APKポーリング中のエラー: $($_.Exception.Message)"
    }
  }

  Start-Sleep -Seconds $IntervalSec
}
