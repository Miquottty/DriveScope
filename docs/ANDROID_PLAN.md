# Android 版 DriveScope 本実装計画(A-S1 記録 / A-S2 振り返り・書き出し / A-S3 堅牢性・品質)

## Context
S0 試作(ドラフト PR #39、`docs/ANDROID_SPIKE.md`)で次が確定した:
- センサーの対応(3 軸 iOS = −Android / 9.80665、時計は elapsedRealtime、生の加速度 200 Hz → 50 Hz 格子、気圧 1 秒平均、
  衛星が来ない間だけ Wi‑Fi の位置)。画面 OFF で 50 Hz・欠落 0.014%。
- **Swift の DriveKit を Android でそのまま使う**(JNI。Pixel 上の書き出しが Mac とバイト一致)。
- 地図は **MapLibre**(Google Maps は #40)。地名は Android の Geocoder で iOS と同じ市名。

前提(ユーザー): 自分用 APK、記録は今の Vlog 制作の流れにそのまま流す、iOS が中心で Android は後追い、
**見た目は iOS と同じデザイン**(design/mock の配色・配置。タブや戻る操作だけ Android の流儀)。対象端末は Pixel 7(縦・横)。
Wear OS・Android Auto・タブレット向け配置・Google Maps は対象外。

## 全体の設計(3 スプリント共通)

### 役割分担
| Kotlin(`Android/app`) | Swift(`Android/swift/DriveKitBridge` → DriveKit) |
|---|---|
| センサー・位置・気圧の取得と iOS の決まりへの変換(試作の `SessionRecorder` から) | **記録エンジン**: `TelemetryEngine`(書き込み `SampleWriter`、統計、マウント補正、衛星判定、watchdog、高度の基準)|
| フォアグラウンドサービス、wake lock、常駐通知 | 停止後の解析: `MountSolver`・`SectionDetector`・`PlacePicker`・`SessionTitle` |
| 画面(Compose)、地図(MapLibre)、地名(Geocoder)、音(AAudio)| リプレイのフレーム(`TelemetryInterpolator`)、品質(`QualityReport`)、書き出し(JSON / GPX / CSV)、復旧時の再集計 |
| セッションの付帯情報(題名・メモ・地名・状態)の保存 | — |

iOS と同じエンジンが `.bin` を書くので、イベントの意味(衛星取得・GPS 途絶・補正更新…)、古い位置の除外、高度の基準などが
自動的に iOS とそろう。iOS 側でエンジンを直せば Android にも入る。

### JNI の形(DriveKitBridge を拡張)
- 記録: `recorderStart(...) → handle(jlong)`、`pushLocation / pushMotion / pushAccel / pushAltitude(handle, …)`、
  `snapshot(handle) → DoubleArray`(10 Hz で Kotlin が読む)、`watchdogEvents(handle)`、`mark / sync / record(handle, …)`、
  `rotateMount`、`flush`、`recorderStop(handle) → summary JSON`。
  Swift 側は JNI から値を流し込む `Push*Source`(AsyncStream)と、`CLOCK_BOOTTIME` の `AndroidClock`(elapsedRealtime と同じ時計)を
  `SensorSuite` にして `TelemetryEngine` を動かす。スナップショットは `onSnapshot` で Mutex に入れ、JNI で読む。
- 解析・表示: `analyze(sessionDir)`(マウント・区間・ピーク G を manifest と JSON に)、`placeCandidates`、`sessionTitle`、
  `replayFrames`(試作済み、区間・マーカーも)、`quality → JSON`、`export(kind, sessionDir, metadataJson, out)`、`recompute(sessionDir)`。
- 文字列・配列のやり取りは試作の `Bridge.swift` の書き方(`GetStringUTFChars` / `NewDoubleArray`)を共通化する。

### DriveKit 側の変更(iOS の動作は変えない)
- DriveRecording を Android でビルド可能に: SwiftData / MapKit を使う `RecordingController`・`SessionFinalizer`・
  `SessionArchiveService`・`ScriptedSessionBuilder` を `#if canImport(SwiftData)` で囲む(試作で DriveStorage にした方法)。
- `TelemetryEngine.elapsed(systemUptime:)` が `ProcessInfo` を直接使っている → エンジンの時計で換算する版に(SYNC 音の時刻用)。
- `ExportMetadata` を JSON から作れるように(Codable、Kotlin が題名・メモ・地名を渡す)。
- 変更のたびに `scripts/xc.sh test`・`build`・`build-device` を通す。

### 保存場所と付帯情報
- `getExternalFilesDir()/Sessions/<UUID>/`: DriveKit の `manifest.json` と `.bin`(iOS と同形式。adb pull → `drivekit-cli` でも読める)。
- 同じフォルダに Kotlin が持つ `session.json`: 題名(手で直したか)、メモ、状態(recording / stopped / recovered)、地名(開始・終了・経由)、
  要約(SwiftData の `DriveSession` と同じ項目)、ルートの縮小版(≤200 点)、区間とその版。データベースは使わず、起動時に
  フォルダを走査して一覧を作る(自分用で数百件程度)。

### 見た目・文言
- `Theme.kt` に design/mock のトークン(試作で作成済み)。数値は等幅。HUD のラベル(ALT / COURSE / DIST / LAT G)と
  START / MARK / HIGHLIGHT / SYNC / STOP は英語のまま、それ以外は `strings.xml` の en / ja。アプリ内の言語切り替え
  (Android 13 以降のアプリ別言語)を iOS と同じく設定に置く。

### ブランチ・テスト・CI
- 各スプリントは `feature/a-sN-…` ブランチ → main へ PR(squash・自動マージ・CI 監視はいつもどおり)。
- GitHub Actions は今の iOS のジョブのまま(DriveKit の変更が iOS を壊さないことはここで保証)。Android のビルドは手元
  (`Android/swift/build-bridge.sh` → `gradlew assembleDebug`)。Swift の Android 用ツールを CI に入れるのは対象外。
- テストは少数・高価値: Kotlin の JVM テスト(センサー変換、`session.json` の読み書き、SYNC 音の時刻換算)と、
  DriveKit 側に Android 形式の小さなセッション(`platform: android` の manifest)を読む 1 件。

## A-S0(A-S1 の最初の PR): 試作から main へ
- 試作(#39)から使うもの: `Android/` の Gradle 一式・センサー変換・記録サービスの骨格・JNI の橋渡しとビルドスクリプト、
  DriveKit の Android 対応(約 60 行)、`SessionExporter.exportDerivingMetadata`、`drivekit-cli`。
- 入れないもの: 試作の確認画面(センサー確認・地図比較)は `debug` ビルドだけの「開発」画面に残すか削除。Google Maps の画面は #40 へ。
- `CLAUDE.md` に Android の節(置き場所・ビルド手順・役割分担・Swift 6.4.0 と NDK r30)、`docs/ANDROID.md` に手順。
- #39 は閉じる(結論は `docs/ANDROID_SPIKE.md` として main に残す)。

## A-S1 記録(終わりの条件: 実車で START → MARK / SYNC → STOP、iPhone と同形式のセッションが残り、`drivekit-cli` で読める)
1. **記録エンジンを Swift に**: 上の JNI と `Push*Source`・`AndroidClock`。試作の Kotlin の書き込み(`StreamWriter`)は廃止し、
   Kotlin は変換した値を push するだけ。5 プリセット(GPS Only / Eco 加速度のみ 10 Hz / Vlog 25 / Logger 50 / Lab 100)の
   センサー周期を Kotlin 側で切り替え。
2. **記録サービス**: 位置情報タイプのフォアグラウンドサービス + wake lock。常駐通知(iOS のライブアクティビティ相当)に
   REC・経過時間・速度・距離・GPS の状態、ボタン MARK / STOP。端末のイベント(画面 ON/OFF、バックグラウンド、温度、省電力、
   電池 5 分ごと)を `record` で events.bin へ(iOS の `DeviceEventMonitor`・`BatteryMonitor` と同じ種類)。
3. **ホーム**: センサー状態(GPS は衛星の数・信号の強さ・L5 まで出す。Android ならでは)、START の円(衛星取得で緑の READY、#38 と同じ)、
   プリセット、最近のセッション。権限(位置・通知)は START 時に求める。
4. **記録 HUD**(縦・横): 速度、ALT / COURSE / DIST、LAT / LONG G と G メーター(#32 と同じく体が押される向きに点が動く)、
   GPS バッジ(ACQUIRING / ±m / GPS SEARCHING、#37)、MARK / HIGHLIGHT / SYNC(3 等分)+ STOP(長押し)。画面を消さない。
5. **SYNC 音と衛星取得音**: iOS と同じ波形("chirp3-v1": 2.5 kHz・40 ms を 0 / 160 / 400 ms、衛星取得は 1.0 → 1.5 kHz)を AAudio で鳴らし、
   出力時刻(`getTimestamp` の nanoTime → elapsedRealtime に換算)を SYNC マーカーの時刻にする。
6. **停止後**: 地名(`placeCandidates` → Geocoder → `sessionTitle`、iOS と同じ題名の作り方)、要約と区間を `session.json` へ。
7. **設定**: 言語(ja / en)、衛星取得音、開発用の速い watchdog。
- 新規の主なファイル: `Android/app/.../recording/`(`SensorPump.kt`・`RecordingService.kt`・`RecordingNotification.kt`)、
  `.../home/HomeScreen.kt`、`.../hud/RecordingHud.kt`・`GMeter.kt`、`.../audio/SyncBeeper.kt`、`.../store/SessionStore.kt`、
  `Android/swift/DriveKitBridge/Sources/DriveKitBridge/Recorder.swift`。
- 確認: 机上で 10 分(50 Hz・欠落 0.1% 未満)→ 実車で iPhone と並走(距離の差 2% 以内、コーナーで横 G の符号が一致 = ジャイロの符号の確認、
  最初の衛星測位までの秒数、SYNC 音がカメラの音声に入り Vlog 側の検出で拾えること)。

## A-S2 振り返り・書き出し(終わりの条件: Pixel の走行を Vlog 制作の流れでそのまま使える)
1. **セッション一覧**: 月ごと(新しい月が上、#36)、ルートの縮小図、RECOVERED の印、削除。
2. **詳細**: 地図(MapLibre: ルート・開始 / 終了 / マーカー)、6 指標、ログ品質の 1 行、地名、メモ(編集)、区間カード、題名の編集。
3. **リプレイ**: 試作の地図比較画面を本番化(既定は暗い地図、国土地理院は暗い配色に作り替えた版を選択肢に)。HUD の値(速度・G メーター・高度)、
   速度の小さなグラフ、マーカーへの移動、区間の一覧、再生速度、FOLLOW / 3D。
4. **書き出し**: DriveKit の JSON / GPX / CSV(30 fps / 10 Hz)を Android の共有メニューへ(FileProvider)。題名・メモ・地名は `session.json` から渡す。
- 確認: Pixel の実車セッションを書き出し → 今の Vlog 制作のツール(HUD・地図・同期)で読めること。同じセッションを Mac の `drivekit-cli` で書き出した結果と一致すること。

## A-S3 堅牢性・品質(終わりの条件: 2 時間記録と、強制終了からの復旧)
1. **復旧**: 記録中にプロセスが落ちたら、サービスの自動再起動(START_STICKY)で同じセッションに追記再開(iOS の堅牢モード・autoResumed 相当)。
   再開できないときは起動時に `recompute` で集計し RECOVERED にする(iOS の復旧シートと同じ流れ)。
2. **Watchdog の通知**: GPS 途絶 15 / 60 / 120 秒の段階(DriveKit の `RecordingWatchdog` の結果を JNI で受けて通知)。
3. **品質画面**: `QualityReport`(サンプル数・間隔・欠落・精度・衛星取得まで・電池・温度・イベント一覧)。Android では衛星の数・信号の強さの推移も
   イベントとして記録して表示する(iOS には無い情報)。
4. **電池と温度**: プリセット別の電池 %/h(`BatteryUsage`)、残量低下時に Eco / GPS Only を提案(iOS と同じく提案のみ)。
5. **長時間**: 2 時間記録でメモリ・ファイルサイズ・発熱・欠落を確認。
- 確認: 記録中に `adb shell am kill` → 自動再開とイベント、端末再起動後の復旧、2 時間の机上記録の品質。

## 確認の基本(各 PR)
- iOS: `scripts/xc.sh test`・`build`・`build-device`(DriveKit を触ったとき)。
- Android: `Android/swift/build-bridge.sh` → `Android/gradlew assembleDebug testDebugUnitTest` → Pixel 7 にインストールして画面を確認、
  記録したセッションを `adb pull` して `swift run drivekit-cli quality / export`。
- 実車の結果は `docs/TESTING.md` の実車テストの表に端末・OS・プリセットつきで追記する。
