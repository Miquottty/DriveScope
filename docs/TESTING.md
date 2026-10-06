# DriveScope — テスト記録

v1 は **すべてシミュレータで開発・検証**した（Xcode 27.2 beta / iOS 27.2 / iPhone 18 Pro ほか）。
シミュレータで確認できない項目は §3 の「実機チェックリスト」にまとめてある。実機テストの結果は §4 の様式で追記する。

## 1. 自動テスト

| コマンド | 内容 |
|---|---|
| `scripts/xc.sh test` | DriveKit パッケージの単体テスト（macOS 上で数秒） |
| `scripts/xc.sh test-ios` | アプリの UI テスト（シミュレータ） |
| `scripts/xc.sh build-device` | iphoneos SDK でのコンパイル確認（署名なし、Watch アプリも含む） |
| `scripts/xc.sh build-watch` | Watch アプリ単体（watchOS シミュレータ） |
| `scripts/xc.sh run-pair [引数]` | iPhone + Watch のペアシミュレータに両方をインストールして起動（既定 iPhone 18 Pro Max、`DRIVESCOPE_PAIR_PHONE`） |

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
| `-SatelliteDelay <秒>`（DEBUG） | 最初の N 秒の fix を Wi‑Fi 風（速度なし・±40 m）にする。屋根の下からの START の再現（ACQUIRING → 衛星取得音） |
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
- Export: JSON（Float ビット一致、sections の位置と null）、CSV（ロケール非依存・SYNC 基準の t=0）、GPX（XMLParser で妥当）

V1.1 で追加（単体テスト 25 本 / 予算 ~50）:

- 速度のモーション補助: Akagi 10 Hz で真値との RMSE が線形補間の 0.6 倍未満（実測 0.0033 vs 0.0247 m/s）、負にならない、fix で GPS と一致、GPS Only は線形のまま
- 区間解析: Akagi のコーナー数が真値に同じ規則をかけた基準の ±10%、0.25 g 以上は同じ向きで一致、停止 1 件（トンネルは停止にならない）、登り 1,230 m ± 15%
- LZFSE アーカイブ: 全リーダーの出力がアーカイブ前後で一致、容量半分未満 / 中断（アーカイブ書き込み後に停止・ゴミ `.tmp`・壊れたアーカイブ）からの修復、アーカイブ済みへの追記を拒否
- 自動再開の判定: 同じ起動で 30 分以内のみ（スリープ・再起動・31 分）/ autoResume が同じファイルに追記し `sessionResumed` + `autoResumed`
- 記録パイプライン: Watch の MARK（source・押下時刻・受信時刻）、Core Location のキャッシュ fix（開始前）を記録しない

V1.1.1 で追加（初回実車で見つかった問題、単体テスト 29 本）:

- Mount Calibration（記録中）: START 時に手持ち → マウントで見つけ直す、ホルダーごと揺れた後は同じマウントを数秒で復元
- Mount Calibration（STOP 後）: 手持ち開始・途中でマウント外・秒切り捨ての古い manifest から、`MountSolver` が正しい軸を解き、マウント外は `hasMotionG = false`、manifest の開始 / 終了時刻を修復
- manifest の日時が小数秒まで往復し、秒単位の古い manifest も読める
- Motion 欠落率: iOS の実レート 49.76 Hz は欠落 0、1 秒の穴は 49 件として数える

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
| iPad | iPad 専用レイアウト（サイドバー / ダッシュボード / 大型 HUD / 地図主体の詳細 / 全画面リプレイ）縦横 | OK |
| 長時間記録 | スクリプト走行 72 分（30 倍速）。位置 4,330・モーション 227,030・気圧 4,381 件、メモリ約 293 MB で横ばい | OK |
| 全プリセット | GPS Only / Eco / Vlog / Logger / Lab で記録 → 再生（単体テスト） | OK |

## 3. 実機チェックリスト（シミュレータで確認できないもの）

- [ ] **実センサー**: Core Motion 25/50/100 Hz・加速度 10 Hz の実効レートと欠落率、気圧高度 — 50 Hz は確認済み（§3.1）
- [ ] **デッドマン通知のタップで記録再開**（シミュレータはカバーシートへのタップ注入が効かない）
- [ ] **画面 OFF 30 分**でルート欠落ゼロ（S2 完了条件）
- [x] **Apple Watch**: Smart Stack に Live Activity、Double Tap で MARK（events の source を確認）
- [ ] **StandBy**（充電中・横向き）の表示
- [x] **Dynamic Island 横向き**（`isDynamicIslandLimitedInWidth`）と Recording HUD 横向き
- [ ] **CarPlay Dashboard** の `.small`
- [ ] **電池**: バッテリー 20% 未満・非充電での提案、batterySnapshot と %/h
- [ ] **位置情報の権限**: While Using、Precise オフ → 一時 Full Accuracy の要求
- [ ] **CLLocationManager と liveUpdates の比較**（Settings → Recording → Location backend、Test B）
- [ ] **オフライン STOP** → 「地名は保留中」→ 復帰後にタイトル生成
- [ ] Export の共有（Files / AirDrop / Mac で開く）

### 3.1 実機で確認済み（2026-09-29、机上）

端末: iPhone 14 Pro / iPhone 16 Pro Max（iOS 27.2 beta 24B5089g）、Apple Watch Series 9。Debug ビルド。
Live Activity の強制終了まわりは実機の XCUITest（一時的なテスト、未コミット）でも確認した。

| 項目 | 結果 |
|---|---|
| 権限ダイアログ（位置情報・モーション・通知・Live Activity） | OK |
| Lock Screen の Live Activity、MARK / STOP（記録中） | OK（MARK 件数バッジ、STOP → SAVED → 詳細） |
| Dynamic Island 横向き・Recording HUD 横向き | OK |
| Watch Smart Stack | `.small` が枠からはみ出していた → 約 76 pt に収まるよう修正して OK |
| Watch Double Tap で MARK | OK。1 回の操作で `MarkIntent` が 2 回届いていた（0–0.1 秒差）→ 0.5 秒以内の重複を無視。Watch のバッジ反映は約 1 秒（Watch ↔ iPhone の往復） |
| 強制終了後の Live Activity | REC のまま残っていた → 起動時に終了、終了直前（`willTerminate`）に終了、stale で `NO DATA` 表示。SIGKILL 後に `NO DATA` になるまで約 90 秒（staleDate 30 秒に対し iOS の反映が遅い） |
| 強制終了後の Live Activity の MARK / STOP | 反応しない: iOS は強制終了されたアプリを intent のために起動しない → `NO DATA` 状態の STOP はアプリを開くリンク（開くと消えて復旧シート） |
| Core Motion 50 Hz（Logger、iPhone 16 Pro Max、9 セッション） | 実効 49.76 Hz（dt 20.1 ms）、欠落 0、時刻の逆行 0、NaN 0。手で強く振って userAcc 最大 12.0 g、回転 最大 26.0 rad/s。飽和なし、\|gravity\| と \|q\| は常に 1.000 |

### 3.2 V1.1 の実機チェックリスト

- [x] **Watch アプリの MARK**（2026-09-30、Series 9 + iPhone 16 Pro Max）: 4 件すべて `source = watch`、重複なし。押下 − 受信は −360〜−322 ms（時計差込み、ばらつき 38 ms）
- [x] **Watch に記録状態を表示**（REC・経過・速度・MARK バッジ）。SYNC でバッジが増えていた → MARK のみ数えるよう修正
- [x] **開始前のキャッシュ fix**: 1 件目が開始 118.8 秒前の fix だった → 記録しないよう修正
- [ ] Watch アプリの STOP（確認ダイアログ）と START（堅牢モード時のみ）
- [ ] 堅牢モード（実車）: 走行中にアプリが落ちたとき iOS が再起動して継続するか、所要時間、復旧シートが出ないこと、`autoResumed`。ユーザーのスワイプ終了時の挙動。STOP 後に再起動されないこと
- [ ] 速度のモーション補助・区間解析（実車）: 実データで区間のしきい値を見直す（`SectionDetector.version` を上げると再計算）。2026-09-30 の初回実車で、キャリブレーションの誤り（下記 §4）を修正した後のコーナー 9 件・Peak G 0.43 G は妥当。しきい値の見直しは峠（Test C）のデータで
- [ ] LZFSE アーカイブ（実機）: 長時間ログの圧縮率と、圧縮済みログを開く時間（Mac で 2 時間ログ約 20–40 ms、目標 150 ms）

## 4. 実車テスト（PLAN §17）

各テストの後に下の表を 1 行追加する（日付・端末・OS・プリセット必須）。

| Test | 日付 | 端末 / OS | プリセット | 時間 | 結果 | メモ |
|---|---|---|---|---|---|---|
| A 静止 10 分 | | | | | | 距離が増えない、G ノイズ、高度ドリフト |
| B 市街地 20–30 分 | 2026-09-30 | iPhone 16 Pro Max / iOS 27.2 | Logger | 36 分・14.5 km | 生データ良好 / 派生値に不具合 → V1.1.1 で修正 | Motion 49.76 Hz・欠落 0、GPS 1 Hz・P50 2.1 m / P95 5.3 m、気圧 0.75 Hz 欠落なし、電池 16.7 %/h。不具合: ①キャリブレーションの「上」を START 直後 1 秒（手持ち）で決めて見直さず、全区間の横 G・ロール・ピッチが誤り ② manifest が開始時刻を秒で切り捨て、GPS がモーションより 0.8 s 遅れ ③欠落率 0.48% は実レートの誤計上 ④ JSON の `endedAt` が常に null ⑤途中 10 分マウント外（手で持った）で Peak G 1.01 G。ほか軽微: `screenOn` 重複、`administrativeArea` が国名、`appVersion` 1.0 |
| B 市街地（衛星取得） | 2026-10-06 | iPhone 16 Pro Max / iOS 27.2 | Logger | 23 分 / 35 分 | 最初の衛星 fix まで 60.8 s / 373 s → V1.2.1 で見える化 | それまでは Wi‑Fi fix のみ（speed −1、約 6 s 間隔）。373 s の回は屋根の下で約 4 分停車、発進後も約 130 s・800 m 衛星なし。衛星 fix 後は約 5 s で ±3 m |
| Android 屋外歩行 | 2026-10-07 | Pixel 7 / Android 16 | Logger | 1.4 分 | 記録・衛星・ジャイロの符号 OK | 屋内から START → 衛星取得まで 22.7 s(それまで Wi‑Fi の位置のみ、satelliteAcquired を記録)、その後 ±1.5〜2 m。モーション 50.00 Hz・欠落 0%。引き返し(GPS の進行方向 88° → 274°、右回り +186°)でジャイロの鉛直軸まわりの積分が −185° = iOS と同じ符号。SYNC 音は本体スピーカー、出力までの遅れ 78〜114 ms。歩行(約 1 m/s)は距離に数えにくい(DriveKit は 1 m/s 以上を移動とみなす。車向けの設計どおり) |
| Android 長時間(机上) | 2026-10-07 | Pixel 7 / Android 16 | Logger | 2 時間 11 分 | 欠落 0・メモリ横ばい・発熱なし | 屋内・USB 給電・画面 ON。モーション 392,661 件 50.00 Hz・欠落 0.000%。アプリのメモリ(PSS)160 → 173 MB で 1 時間目以降横ばい(ネイティブ 13.9 → 18.5 MB、2 時間目で頭打ち)。容量 29.8 MB(約 13.7 MB/時、ほぼモーション)。電池温度 31.6 → 30.2 ℃、温度状態 0 のまま。屋内なので GPS は途絶 1 回・P50 11.7 m。気圧の記録が 1.12 s 間隔になっていた(1 秒平均の窓のずれ)→ 起動時計の 1 秒ごとの固定の窓に修正(70 秒で 70 件・1.00 s 間隔を確認) |
| C 峠 30–60 分 | | | | | | 獲得標高、横 G 符号、Calibration、トンネルの Watchdog |
| D 長時間 2 時間以上 | | | | | | メモリ・容量・発熱・欠落・Recovery |
| E 電池比較 60 分 × 3 | | | GPS Only / Eco / Logger | | | 画面 OFF・非充電の %/h → PLAN §2.2.2 を置き換え |
