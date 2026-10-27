# AGENTS.md

本リポジトリ `adb-wifi-autoinstall` で作業する AI コーディングエージェント向けのプロジェクト固有指示の**正本**。

## プロジェクト概要

- **プロジェクト名**: adb-wifi-autoinstall（ADB Utilities for Unity Android Development）
- **概要**: Unity Android 開発向けの ADB ユーティリティ集。Wi-Fi ADB 接続を維持して APK 更新を全端末へ自動インストールする機能と、複数端末の logcat をデバイス別ファイルへ記録する機能を持つ
- **ステータス**: 運用中（CLI スクリプト）。タスクトレイ常駐アプリへの置き換えを #13 で設計予定
- **リポジトリ**: <https://github.com/dilander/adb-wifi-autoinstall>
- **セッションアイコン**: 📲

## 技術スタック

| 領域 | 採用 | バージョン / 出典ファイル |
| --- | --- | --- |
| 言語 / ランタイム | PowerShell 5.1 以上（Windows 専用） | `adb-wifi-autoinstall.ps1` の `#requires -version 5.1` |
| 起動 | `.bat` ラッパー | `adb-wifi-autoinstall.bat` は `pwsh` があれば優先、`start_logcat.bat` / `stop_logcat.bat` は `powershell.exe` 固定 |
| 外部ツール | `adb`（PATH 上） | 版はマシン依存。`adb version` で実測する（#14） |
| 並列実行 | `Start-ThreadJob`（無ければ `Start-Job` にフォールバック） | `adb-wifi-autoinstall.ps1`。読み込むモジュール `ThreadJob` は deprecated（#14） |

> バージョンは上記「出典ファイル」を正とする（推測で書かない）。

## 開発コマンド

ビルド・自動テストは無い。

- `adb-wifi-autoinstall.bat` — Wi-Fi Auto Install を起動（パラメータは README の「設定（パラメータ）」）
- `start_logcat.bat` / `stop_logcat.bat` — logcat 記録の開始 / 停止
- 構文チェック — `.ps1` を変更したら、`powershell.exe`（5.1）と `pwsh`（7）の両方で次を実行し、全ファイルが `errors=0` になることを確かめる

  ```powershell
  Get-ChildItem *.ps1 | ForEach-Object { $t = $null; $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$t, [ref]$e); "{0}: errors={1}" -f $_.Name, $e.Count }
  ```

## アーキテクチャ / リポジトリ構成

- `adb-wifi-autoinstall.ps1` — 端末収集（`Refresh-Targets`）→ `adb tcpip` / `adb connect` の維持（`Ensure-ConnectedSingle`）→ APK 更新のポーリング検知 → 並列インストール（`Install-ApkParallel`）。結果は音で通知する（全台成功で `SystemSounds.Asterisk`、失敗ありで `Hand`）。ターゲットが 0 台の間は 2 秒おきに待ち続け、その後は末尾の `while ($true)` メインループで回る。自分では終了しない
- `start_logcat.ps1` — 端末ごとに `adb logcat -c` でバッファを消してから、非表示の `cmd.exe` で `adb logcat -v threadtime -s Unity` を起動し、`Logs/<デバイス名>_unity_<yyyyMMdd_HHmmss>.log` へ記録する
  - `<デバイス名>` は `device_nicknames.txt` のニックネーム（無ければシリアル）から括弧を除き、空白とコロンを `_` に置き換えたもの（`Resolve-Nickname`）
  - PID を `logcat_pids.txt` に控えて 2 重起動を防ぐ
  - Ctrl+C で停止する（`Stop-Sessions`）。`/F` なしの `taskkill` で graceful に止め、5 秒待っても残るものだけ `/F` で強制終了する
- `stop_logcat.ps1` — `logcat_pids.txt` を読んで同じ手順で停止するフォールバック
- `device_nicknames.txt` — シリアル→ニックネームの対応（各自が `.example` から作る。追跡対象外）
- `Logs/` / `logcat_pids.txt` — 実行時の生成物（追跡対象外）

利用者向けの仕様・使い方は `README.md` が正本。

## コーディング上の注意

- **非 ASCII 文字（日本語）を含む `.ps1` は UTF-8（BOM 付き）で保存する。** Windows PowerShell 5.1 は BOM なしの UTF-8 を ANSI（CP932）として読むため、文字化けや構文エラーになる。現状、日本語を含む `adb-wifi-autoinstall.ps1` は BOM 付き、ASCII のみの `start_logcat.ps1` / `stop_logcat.ps1` は BOM なし
- 変更は PowerShell 5.1 と 7 の双方で動く書き方にする（`.bat` によって起動するエンジンが異なる）

## このプロジェクトで特に確認すべき判断

- 端末側の状態を変える adb 操作（`adb tcpip` の発行条件、インストールの対象端末・方式、`logcat -c` 等）の追加・変更
- 端末の切断・再接続の判定条件やポーリング間隔の既定値
- 通知の仕様変更（現行は上記の音のみ）

## プロジェクト運用メモ

- **動作確認の多くは実機の Android 端末と物理操作（USB の抜き差し・Wi-Fi の切断）を要する。**
- **端末を使わずにスクリプトを実行して確かめるときは、次の前提と範囲を守る。** 前提が崩れていれば実行しない
  - 前提: `adb devices` に端末が 1 台も無いこと（あれば `adb tcpip` や `logcat -c` が端末に走る）。`logcat_pids.txt` が無いこと（あれば記録中のセッションがあり、`stop_logcat.ps1` がそれを止めてしまう）
  - 起動方法: `.bat` は末尾の `pause` で返らないので使わず、`.ps1` を直接、時間制限を付けて実行する
  - 確かめられる範囲:
    - `start_logcat.ps1` が `No devices connected.` を出して exit 1 で終わること
    - `stop_logcat.ps1` が PID ファイル無しのメッセージを出して exit 0 で終わること
    - `adb-wifi-autoinstall.ps1` が待機のメッセージを出して待ち続けること（自分で止める）
- **Issue 添付の Google Drive フォルダ**: `gdrive:adb-wifi-autoinstall-issue-attachments/`
  （手順はグローバル設定「Issueへのファイル添付」を参照）
