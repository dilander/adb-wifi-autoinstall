# ADB Utilities for Unity Android Development

Unity Android 開発者向けの ADB ユーティリティ集です。APK の自動インストールと、複数端末の logcat 記録を提供します。

| ユーティリティ | スクリプト | 用途 |
|---|---|---|
| **Wi-Fi Auto Install** | `adb-wifi-autoinstall.ps1` | Wi-Fi ADB 接続を維持しつつ、APK 更新を検知して全端末へ自動インストール |
| **Multi-device Logcat Recorder** | `start_logcat.ps1` / `stop_logcat.ps1` | 接続中の全端末から Unity タグの logcat をデバイス別ファイルにバックグラウンド記録 |

両者は相補的に使えます: APK を自動インストール → アプリ再起動 → logcat で挙動確認、というワークフローです。

---

## 目次

- [前提・動作環境](#前提動作環境)
- [Wi-Fi Auto Install](#wi-fi-auto-install)
  - [概要](#概要)
  - [使い方](#使い方)
  - [設定（パラメータ）](#設定パラメータ)
  - [出力・ログ](#出力ログ)
- [Multi-device Logcat Recorder](#multi-device-logcat-recorder)
  - [概要](#概要-1)
  - [使い方](#使い方-1)
  - [デバイスニックネーム](#デバイスニックネーム)
  - [仕組み](#仕組み)
- [セキュリティ・注意事項](#セキュリティ注意事項)
- [AI 生成についての明示](#ai-生成についての明示)
- [貢献・ライセンス](#貢献ライセンス)

---

## 前提・動作環境

- Windows（PowerShell 5.1 以上）
- `adb` が PATH に通っていること
- 対象端末の USB デバッグが有効であること

---

## Wi-Fi Auto Install

### 概要

`adb-wifi-autoinstall.ps1` は以下を組み合わせたユーティリティです。

- **ADB 接続ウォッチドッグ**: 端末が切断された場合、自動で再接続を試みます（USB 接続時は `adb tcpip` で復旧を試行）
- **複数端末対応**: USB 接続された全 Android 端末を自動で収集し、Wi-Fi ADB のターゲットとして管理。実行中に接続された端末も動的に取り込みます
- **APK 更新監視**: 指定ディレクトリの最新 APK を監視し、更新があれば全ターゲットへ並列で `adb install` を実行（FileSystemWatcher + ポーリングの二重検知）
- **音声通知**: インストール結果に応じて Windows システム音で通知（全台成功なら Asterisk、1台でも失敗なら Hand）

初回は USB 接続で各端末の IP を取得する必要があります（`adb tcpip` 有効化のため）。

主に XREAL 向け Unity 開発者（Wi-Fi 経由で ADB 接続を維持しつつ、Unity の Run を使わずにビルド→インストールを回したい方）を想定しています。

### 使い方

```powershell
# バッチファイルから実行（推奨）
adb-wifi-autoinstall.bat

# PowerShell から直接実行
powershell -ExecutionPolicy Bypass -File "adb-wifi-autoinstall.ps1"

# パラメータ指定の例
powershell -ExecutionPolicy Bypass -File "adb-wifi-autoinstall.ps1" -Port 5555 -WatchDir "C:\path\to\apk_dir" -ApkFilter "*.apk" -IntervalSec 5
```

### 設定（パラメータ）

| パラメータ | デフォルト | 説明 |
|---|---|---|
| `Port` | 5555 | adb tcpip 用ポート |
| `IntervalSec` | 5 | ウォッチドッグ・メインループの待機間隔（秒） |
| `WatchDir` | スクリプト起動ディレクトリ | APK を監視するディレクトリ |
| `ApkFilter` | `*.apk` | 監視するファイルのフィルタ |
| `DebounceMs` | 1200 | FileSystemWatcher のデバウンス時間（ミリ秒） |
| `PollApkEverySec` | 5 | ポーリング間隔（秒） |

### 出力・ログ

- 接続状態は `接続OK: N/M 台 (last update: HH:mm:ss)` の形式で同一行上書き表示
- 重要イベント（端末検出、接続失敗/復旧、APK 更新検知、インストール結果など）はタイムスタンプ付きで改行出力
- 並列インストール結果は `並列インストール結果: 成功=X / 失敗=Y / 合計=Z` として集約表示

---

## Multi-device Logcat Recorder

### 概要

PC に接続中の全 Android 端末（Meta Quest 等）から、**デバイス別ファイル**に Unity タグの logcat をバックグラウンド記録します。

- 接続中の全端末を自動検出
- 端末ごとに非表示の `cmd.exe` プロセスで `adb logcat` を実行
- ログは `Logs\<デバイス名>_unity.log` に出力
- Ctrl+C で graceful に停止し、バッファを確実にフラッシュ
- 2重起動防止機能付き

### 使い方

**開始:**

```powershell
# バッチファイルから実行（推奨）
start_logcat.bat

# PowerShell から直接実行
powershell -ExecutionPolicy Bypass -File "start_logcat.ps1"
```

**停止:**

実行中のターミナルで **Ctrl+C** を押してください。graceful に停止し、ログバッファがフラッシュされます。

Ctrl+C が使えない場合（ターミナルが応答しない等）はフォールバック用の停止スクリプトを使います:

```powershell
stop_logcat.bat
```

**出力例:**

```
Starting logcat for 2 device(s) (hidden)...

  [Meta_Quest_3_vanilla] pid=56240  ->  Logs\Meta_Quest_3_vanilla_unity.log
  [192.168.1.100_5555]   pid=58488  ->  Logs\192.168.1.100_5555_unity.log

Recording. Press Ctrl+C to stop and flush.
```

### デバイスニックネーム

デフォルトでは ADB シリアル番号がそのままログファイル名に使われます。分かりやすい名前を付けたい場合は、`device_nicknames.txt.example` をコピーして `device_nicknames.txt` を作成し、マッピングを記述してください。

```powershell
copy device_nicknames.txt.example device_nicknames.txt
```

フォーマット:

```
SERIAL=Nickname
```

例:

```
2G0YC1ZG3P01QW=Meta Quest 3 (vanilla)
192.168.1.100:5555=Meta Quest 3 (wifi)
```

`device_nicknames.txt` は `.gitignore` 対象のため、各開発者が自分の環境に合わせて編集します。

### 仕組み

- `start_logcat.ps1` が `adb devices` で接続端末を列挙し、端末ごとに非表示の `cmd.exe` プロセスを起動して `adb logcat -v threadtime -s Unity > ログファイル` を実行します
- 停止時は `taskkill /PID`（`/F` なし）で WM_CLOSE → CTRL_CLOSE_EVENT を送り、adb の CRT が stdio バッファをフラッシュしてからプロセスが終了します。これにより確実にログが書き出されます
- 5秒以内に終了しない場合のみ `/F` で強制 kill します（ログが途切れる可能性あり）

---

## セキュリティ・注意事項

- これらのスクリプトは端末の ADB インタフェースを操作します。公開環境や不特定多数が接続するネットワーク上での運用には十分注意してください
- 自動インストール機能を使う場合、誤った APK をインストールするリスクがあります。監視ディレクトリの管理は慎重に行ってください
- スクリプトを配布・実運用する前に必ずコードレビューとテストを行ってください

## AI 生成についての明示

このリポジトリ内のファイルには、AI（生成モデル）による生成または編集支援が含まれています。最終的なレビュー、テスト、運用判断は人間の担当者が行ってください。

## 貢献・ライセンス

- バグ修正や改善提案は Issue または Pull Request で歓迎します
- ライセンスについては [LICENSE](LICENSE) を参照してください
