# DriveScope — テスト記録

v1 は **すべてシミュレータで開発・検証**した（Xcode 27.2 beta / iOS 27.2 / iPhone 18 Pro ほか）。
シミュレータで確認できない項目は §3 の「実機チェックリスト」にまとめてある。実機テストの結果は §4 の様式で追記する。

## 1. 自動テスト

| コマンド | 内容 |
|---|---|
| `scripts/xc.sh test` | DriveKit パッケージの単体テスト（macOS 上で数秒） |
| `scripts/xc.sh test-ios` | アプリの UI テスト（シミュレータ） |
| `scripts/xc.sh build-device` | iphoneos SDK でのコンパイル確認（署名なし） |

UI テスト（2 本）:

- `testRecordStopReplay`: スクリプト走行で START → MARK → STOP 長押し → 詳細 → リプレイ再生 → 書き出し（GPX）
- `testKilledRecordingIsRecovered`: 記録中に強制終了 → 再起動 → 復旧シート → RECOVERED

起動引数（デバッグ / テスト用）:

| 引数 | 効果 |
|---|---|
| `-DriveSim akagi -DriveSimSpeed N` | 決定論的なスクリプト走行（権限不要、N 倍速） |
| `-UITest` | メモリ内ストア + 一時フォルダ（実データに触れない、通知の許可ダイアログを出さない） |
| `-UITestKeepData` / `-UITestFresh` | UI テスト用データを再起動後も保持 / 初期化 |
| `-SeedSession <秒>`（DEBUG） | Akagi のスクリプト走行セッションを生成（例: 7200 で 2 時間ログ） |
| `-appLanguage ja` / `en` | アプリ内言語 |
| Settings → Debug → Fast watchdog | Watchdog の閾値を 1/10 に短縮 |

主な単体テスト（テストは意図的に少数・高価値に絞っている）:

- バイナリ記録: レコード配置、`write` 後の強制終了・書き込み途中の切断からの復旧、静かなストリームの時間 flush
- 記録パイプライン: スクリプト走行（100 倍速）で START → MARK → STOP、ファイル・統計・キャリブレーションの整合
- 復旧: 実際の kill（バッファ喪失）→ resume が同じファイルに追記 → recover がファイルから統計を再計算
- Watchdog: 段階遷移、サスペンドで全段を飛び越えた場合、デッドマン再登録
- Mount Calibration: 横置き・25° ヨー・15° 傾きの未知のマウントを復元し、コーナーの横 G 符号が正しい
- 統計: 駐車中の GPS ドリフトで距離・獲得標高が増えない（Test A 相当）、電池 %/h（画面 ON/OFF 別）
- 地名: オフライン → pending → 再試行でタイトル生成、ユーザー編集タイトルは上書きしない
- Replay: 2 時間 Logger ログが 100 ms 未満で開き、フレームがスクリプトと一致（位置・速度・course・横 G 符号・トンネル）
- Export: JSON（Float ビット一致）、CSV（ロケール非依存・SYNC 基準の t=0）、GPX（XMLParser で妥当）

## 2. シミュレータで確認済み（2026-09-29）

| 項目 | 方法 | 結果 |
|---|---|---|
| 記録 → 停止 → 軌跡 | `-DriveSim akagi` / `simctl location` ルート | OK |
| バックグラウンド継続 | ルート再生中にホームへ（Dynamic Island に REC） | OK |
| Watchdog 1 段目 | Settings → Debug → Fast watchdog、ルート停止 | 「GPS 信号なし」通知 OK |
| Watchdog 2 段目（デッドマン） | 記録中に `simctl terminate` | 約 18 秒後に通知 OK（短縮モード） |
| 強制終了からの復旧 | 終了 → 再起動 → Recovery シート → 復元 | OK |
| Live Activity | ロック画面の MARK / STOP、Dynamic Island compact / expanded | OK |
| Mount Calibration | スクリプト走行で CAL 表示、右カーブで横 G がマイナス・点が右 | OK |
| 地名・自動タイトル | STOP 後 約 2 秒でタイトル（ja / en） | OK |
| 言語切替 | Settings で即時切替（ナビタイトル含む） | OK |
| 記録の再開 | 強制終了 → 復旧シートの「記録を再開」 | 同じファイルに追記 OK |
| リプレイ | 2 時間ログを即時に開き 2× 再生、地図追従 | OK |
| 書き出し | JSON / GPX / CSV 30 fps / 10 Hz → `jq` / `xmllint` / 共有シートで「ファイルに保存」 | OK |
| iPad | iPad Pro 11 インチでの表示（本文幅 640 pt に制限） | OK |

## 3. 実機チェックリスト（シミュレータで確認できないもの）

- [ ] **実センサー**: Core Motion 25/50/100 Hz・加速度 10 Hz の実効レートと欠落率、気圧高度
- [ ] **デッドマン通知のタップで記録再開**（シミュレータはカバーシートへのタップ注入が効かない）
- [ ] **画面 OFF 30 分**でルート欠落ゼロ（S2 完了条件）
- [ ] **Apple Watch**: Smart Stack に Live Activity、Double Tap で MARK（events の source を確認）
- [ ] **StandBy**（充電中・横向き）の表示
- [ ] **Dynamic Island 横向き**（`isDynamicIslandLimitedInWidth`）と Recording HUD 横向き
- [ ] **CarPlay Dashboard** の `.small`
- [ ] **電池**: バッテリー 20% 未満・非充電での提案、batterySnapshot と %/h
- [ ] **位置情報の権限**: While Using、Precise オフ → 一時 Full Accuracy の要求
- [ ] **CLLocationManager と liveUpdates の比較**（Settings → Recording → Location backend、Test B）
- [ ] **オフライン STOP** → 「地名は保留中」→ 復帰後にタイトル生成
- [ ] Export の共有（Files / AirDrop / Mac で開く）

## 4. 実車テスト（PLAN §17）

各テストの後に下の表を 1 行追加する（日付・端末・OS・プリセット必須）。

| Test | 日付 | 端末 / OS | プリセット | 時間 | 結果 | メモ |
|---|---|---|---|---|---|---|
| A 静止 10 分 | | | | | | 距離が増えない、G ノイズ、高度ドリフト |
| B 市街地 20–30 分 | | | | | | 背景 / ロック継続、backend 比較（間隔・P95・欠落） |
| C 峠 30–60 分 | | | | | | 獲得標高、横 G 符号、Calibration、トンネルの Watchdog |
| D 長時間 2 時間以上 | | | | | | メモリ・容量・発熱・欠落・Recovery |
| E 電池比較 60 分 × 3 | | | GPS Only / Eco / Logger | | | 画面 OFF・非充電の %/h → PLAN §2.2.2 を置き換え |
