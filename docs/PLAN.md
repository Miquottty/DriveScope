# DriveScope — 実装計画

**Version:** 1.0 (2026-09-29)
**Target:** iOS 27 / Xcode 27.2 / Swift 6.4 / SwiftUI
**Bundle ID:** `com.miquottty.DriveScope`
**Team ID:** `3X6HG4QJA8`
**Design mock:** https://claude.ai/artifact/AFmN9QtGv2Yo15gxyZfBte（スナップショット: `design/mock/`）
**Distribution:** 個人利用のみ（App Store / 外部配布なし）

### 配布前提: 個人利用（App Store 非公開）
- Xcode から自分の端末へ直接インストールする（有料 Developer Program の署名、プロファイル有効期限 1 年。期限前に再インストール）。必要なら TestFlight の内部テストも可。
- App Review Guidelines への適合（審査向けの説明文・スクリーンショット・プライバシー栄養ラベル等）は対象外。
- ただし OS が強制するものは引き続き必要: 位置情報・モーション等の利用目的文言（Info.plist）、Background Mode 宣言、ユーザー許可フロー。
- **Apple が個別付与する管理対象の権限（CarPlay 等）は、個人利用でも実機では承認なしに使えない**。本プロジェクトでは申請しない（§19）。

iPhone 単体で車載 Vlog 向けテレメトリ（位置・速度・高度・姿勢・加速度）を記録し、走行後にルートと HUD を時系列再生・エクスポートする。将来の動画 HUD オーバーレイの基盤になる。

---

## 0. 元プラン（v0.1）からの主な変更点

| 項目 | v0.1 | v1.0 | 理由 |
|---|---|---|---|
| ターゲット | 未指定 | iOS 27 / Xcode 27.2 | 最新 API（Live Activity 横向き / StandBy、SwiftData Codable 属性、Swift 6.4）を使う |
| サンプル永続化 | SwiftData `@Model` | **追記型バイナリファイル**（セッションごと） | 20〜100 Hz × 数時間を SwiftData に入れると fetch・メモリ・削除が破綻する。追記型はクラッシュ耐性も高い |
| Motion 更新周期 | 20 Hz | **50 Hz 既定**（GPS Only / Eco / Vlog 25 / Logger 50 / Lab 100 の 5 プリセット） | 20 Hz では横 G ピークが潰れる。iPhone の上限は 100 Hz（`CMBatchedSensorManager` は watchOS 専用）。電池重視の GPS Only / Eco を用意 |
| 配布 | 未定義 | **個人利用のみ（App Store 非公開）** | 審査対応は不要。Apple 管理の権限（CarPlay）は申請しないためシミュレータ検証に留める |
| Live Activities | V2 | **MVP** | 画面 OFF・StandBy・CarPlay・Watch で「記録中」が見えることは信頼性そのもの |
| Apple Watch | V2 | **MVP は Smart Stack 表示 + Double Tap MARK（Watch アプリなし）**、Watch アプリは V1.1、心拍は V2 検討 | 最小コストで「ハンドルを握ったまま MARK」を実現 |
| Recording 画面のミニ Map | あり | **なし** | 描画コストが高く、ロガー用途では数値 HUD に集中すべき。Map は Detail / Replay で見せる |
| SYNC / MARK | V1.1 | **MVP**（Recording 常設）。HIGHLIGHT（見どころ）を V1.1 で追加 | 実装は数行で、Vlog 同期の中核 |
| 時刻基準 | elapsedTime のみ | **`startedAt(Date)` + `startUptime(systemUptime)` ペアを保存** | Motion の timestamp は boot 基準。絶対時刻に戻せないと動画同期ができない |
| Mount Calibration | 「基準姿勢を記録」 | **重力で pitch/roll + 発進加速で yaw 自動決定 + 90° 手動補正** | 重力だけでは前方向が決まらない |
| 地名 | 未定義 | STOP 時に `MKReverseGeocodingRequest` で代表点を逆ジオコーディングし保存 | `CLGeocoder` は iOS 26 で非推奨 |
| 停止検知 | なし | **RecordingWatchdog（2 段）+ events ストリーム** | 更新停止・サスペンドをユーザーに通知し、記録として残す |
| ローカライズ | 未定義 | **日本語 / 英語**、既定は OS 言語、アプリ内で切替可 | — |

---

## 1. MVP のゴールと完成条件

### ゴール
1. START でテレメトリ記録開始（フォアグラウンドで開始）
2. バックグラウンド・画面ロック中も記録継続
3. 走行中 HUD（縦・横・Live Activity・StandBy）
4. STOP でセッション確定・地名メタ付与
5. セッション一覧・詳細・Timeline Replay
6. JSON / CSV / GPX エクスポート
7. 後から Action Camera 映像と同期できる時刻情報（絶対時刻 + elapsed + SYNC マーカー）

### 完成条件（Definition of Done）
状態（2026-09-29）: ✅ = シミュレータ / 自動テストで確認済み、📱 = 実機で確認（`docs/TESTING.md` §3 のチェックリスト）

- [x] 30〜60 分以上の連続記録 — ✅ スクリプト走行 72 分（30 倍速）、メモリ横ばい（約 293 MB）
- [ ] 画面 OFF / バックグラウンドで GPS・Motion・Altimeter が継続 — ✅ バックグラウンド継続（シミュレータ GPS）／📱 画面 OFF 30 分・実センサー
- [x] 強制終了・クラッシュ後に直前 2 秒までのログが復旧できる — ✅ 単体テスト（kill → recover / resume）+ UI テスト
- [x] Location（座標・速度・高度・方位・4 種精度）を保存 — ✅
- [x] Motion 50 Hz（userAcc / gravity / rotationRate / attitude / mag）を保存 — ✅（72 分で 227,030 件、欠落 ≈ 0%）
- [ ] 5 プリセット（GPS Only / Eco / Vlog / Logger / Lab）で記録・再生でき、プリセット別の電池消費 %/h を実測済み — ✅ 記録・再生（単体テスト）／📱 電池 %/h 実測（Test E）
- [x] 気圧高度を保存 — ✅（シミュレータは派生値、📱 で実センサー確認）
- [x] Map にルート表示、Timeline で Map と HUD が同期 — ✅
- [x] JSON / CSV / GPX が外部共有できる — ✅（共有シート →「ファイルに保存」、`jq` / `xmllint`）
- [ ] Live Activity（Lock Screen / Dynamic Island 縦横 / StandBy / small / Watch Smart Stack） — ✅ Lock Screen / Dynamic Island 縦、MARK / STOP／📱 Lock Screen・Dynamic Island 縦横・Watch Smart Stack（2026-09-29）、残り StandBy・CarPlay small
- [x] Watch の Double Tap で MARK — 📱 Series 9 で確認（2026-09-29、events の source = liveActivity）
- [x] Watchdog 通知が停止時に届く — ✅（GPS 途絶通知、強制終了後のデッドマン通知）
- [x] 日本語 / 英語 UI、アプリ内切替 — ✅
- [ ] 実車テスト A〜D 完走 — 📱

---

## 2. 取得するセンサーデータ

### 2.1 Core Location
```swift
manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
manager.distanceFilter = kCLDistanceFilterNone
manager.activityType = .automotiveNavigation
manager.pausesLocationUpdatesAutomatically = false
manager.allowsBackgroundLocationUpdates = true
manager.showsBackgroundLocationIndicator = true
```
- iPhone 内蔵 GNSS は実質 **1 Hz 上限・不定期**。固定レートを前提にしない。
- `LocationSource` プロトコルの裏に `CLLocationManager` 実装と `CLLocationUpdate.liveUpdates(.automotiveNavigation)` + `CLBackgroundActivitySession` 実装を両方置き、Test B の実測（間隔・精度 P95・欠落・背景継続）で採用を決める。
- START 前に `accuracyAuthorization == .fullAccuracy` を確認。`.reducedAccuracy` なら `requestTemporaryFullAccuracyAuthorization(withPurposeKey:)`。

保存項目: `timestamp, lat, lon, altitude, speed, course, hAcc, vAcc, speedAcc, courseAcc, flags(sourceInfo)`

### 2.2 Core Motion
- `CMMotionManager.startDeviceMotionUpdates(using:)`、参照フレームは `.xArbitraryCorrectedZVertical` を既定とし、`.xMagneticNorthZVertical` と車内で比較（磁気ノイズ）。
- 保存項目（device motion）: `timestamp(uptime), userAcc xyz, gravity xyz, rotationRate xyz, attitude quaternion wxyz, magneticField xyz + accuracy`
- 保存項目（加速度のみ、Eco）: `timestamp(uptime), acceleration xyz`（重力込みの生値。重力方向は低域通過で推定）
- **Raw は端末座標系のまま保存**。車両座標系への変換（Calibration）は再生・派生時に適用する。

### 2.2.1 キャプチャプリセット
| プリセット | GPS | Motion | 失うもの | Live Activity 更新 |
|---|---|---|---|---|
| **GPS Only** | 1 Hz | なし | G の実測値。代わりに **GPS 推定横 G**（速度 × course 変化率 / g、1 Hz なのでピークは鈍る）を表示・派生 | 5 秒 |
| **Eco** | 1 Hz | **加速度のみ 10 Hz（`startAccelerometerUpdates`、ジャイロ OFF）** | 姿勢（roll / pitch / yaw）、角速度。前後 G・横 G は Calibration 後に算出可 | 5 秒 |
| Vlog | 1 Hz | device motion 25 Hz | — | 2 秒 |
| **Logger（既定）** | 1 Hz | device motion 50 Hz | — | 2 秒 |
| Lab | 1 Hz | device motion 100 Hz | — | 2 秒 |

- GPS の精度設定（BestForNavigation）はどのプリセットでも下げない（ロガーの本体）。
- プリセットは**セッション単位で固定**（MVP では記録途中の変更不可。データ形式の混在を避ける）。
- 電池残量 20% 未満かつ非充電時、START 前と記録中に「Eco / GPS Only に切り替えますか」を**提案のみ**（自動切替しない。記録中の提案は次回セッションへの推奨として表示）。

### 2.2.2 電池消費の見込み（推定、S3 で実測して置き換える）
| 消費源 | 目安 |
|---|---|
| 画面（HUD 表示） | 1〜2 W（最大要因） |
| GPS（BestForNavigation） | 0.15〜0.3 W |
| Motion 50 Hz（ジャイロ + フュージョン + CPU 起床） | 0.03〜0.08 W |
| 気圧・書き込み・Live Activity | 0.01〜0.03 W |

| 状態（電池 約 15 Wh 換算） | Logger 50 Hz | GPS Only | 差 |
|---|---|---|---|
| 画面 ON | 約 13〜15 %/h | 約 12〜14 %/h | 約 1 %/h |
| 画面 OFF | 約 2.5〜3 %/h | 約 2〜2.5 %/h | 相対 15〜25% 減 |

電池対策の優先順位: ① 画面 OFF / HUD 減光（StandBy・Live Activity 運用）② ジャイロ停止 ③ Motion 周期低下 ④ Live Activity 更新間隔 ⑤ GPS 精度低下（プリセットには入れない）。

### 2.3 CMAltimeter
- `relativeAltitude`, `pressure`。開始時 GPS 高度を baseline としてセッションに保存し、表示用「気圧補正高度 = baseline + relative」を派生する。

### 2.4 記録しないもの（V2 以降）
OBD-II / CAN / 外部 GNSS / Apple Watch をセンサーとして使うこと（心拍・腕の Motion）/ HealthKit / カメラ撮影 / 動画 import・同期・HUD レンダリング / iCloud / CarPlay アプリ本体 / Lap timer / Map matching / ナビ

---

## 3. 時刻設計

```
Session
  startedAt   : Date            (絶対時刻, UTC)
  startUptime : TimeInterval    (ProcessInfo.systemUptime, Motion 基準)
  timeZone    : String

Location sample : timestamp(Date) → elapsed = timestamp - startedAt
Motion sample   : timestamp(uptime) → elapsed = timestamp - startUptime
Altitude sample : 同上（CMLogItem）
Marker / Event  : elapsed + Date の両方
```
- 全ストリームを `elapsed` に正規化して合成する。絶対時刻は `startedAt + elapsed` で復元。
- `startedAt` は Location と Motion をつなぐ基準なので、manifest には小数秒（µs）まで書く。秒で切り捨てると GPS がモーションより最大 1 秒遅れる（初回実車で 0.8 秒。V1.1.1 で修正、古い manifest は SwiftData の値で `ensureSections` 時に修復）。
- 実測: Core Location の速度はモーションより約 0.6 秒遅れる（初回実車で dv/dt と前後加速度の相関が最大になるずれ）。現状は補正しない。
- 動画同期は SYNC マーカーの `elapsed` を t=0 とするオフセット方式（VlogTrack 参照）。

---

## 4. データ保存設計

### 4.1 方針
- **SwiftData** = セッションメタ・統計・地名・Marker・Calibration（`@Attribute(.codable)`）。一覧・検索・並べ替えに使う。
- **バイナリファイル** = サンプル本体。セッションごとのフォルダに追記型・固定長レコードで保存。

```
Application Support/Sessions/<sessionID>/
  manifest.json      … schema version, record sizes, startedAt/startUptime, preset
  location.bin       … 72 B / record
  motion.bin         … 72 B / record (device motion, Float32, timestamp Double)
                       または 20 B / record (Eco: 加速度のみ)。manifest に形式を記録。GPS Only では作らない
  altitude.bin       … 16 B / record
  events.bin         … 24 B / record (kind, elapsed, value)
```
- 各 `.bin` は 32 B ヘッダ（magic, version, recordSize）+ レコード列。**復旧可能件数 = (fileSize - header) / recordSize**。
- 書き込みは `SampleWriter` actor が担当。メモリバッファ → **2 秒ごと、または 256 レコードごとに `write(2)` + `fsync` は 10 秒ごと**。
- STOP・`willTerminate`・`didEnterBackground` の最終 flush は `withTaskCancellationShield` で保護。
- ファイル保護は既定（`completeUntilFirstUserAuthentication`）のまま。`.complete` はロック中に書けないので禁止。
- 再生時は `mmap`（`Data(contentsOf:options:.alwaysMapped)`）→ `Span` で配列化。2 時間ログでも即時に開く。

### 4.2 SwiftData モデル
```swift
@Model final class DriveSession {
    var id: UUID
    var startedAt: Date
    var startUptime: TimeInterval
    var endedAt: Date?
    var timeZoneID: String
    var state: RecordingState          // recording / stopped / recovered / discarded
    var preset: CapturePreset          // gpsOnly / eco / vlog / logger / lab
    var batteryUsagePerHour: Double?   // 実測 %/h（events の電池記録から算出）
    var title: String                  // 自動生成 → ユーザー編集可
    var titleIsUserEdited: Bool
    var notes: String?
    var appVersion: String
    var deviceModel: String
    var osVersion: String

    // 統計（STOP 時に確定、Recovery 時に再計算）
    var duration: TimeInterval
    var distance: Double
    var maxSpeed: Double
    var avgSpeed: Double
    var elevationGain: Double
    var peakLateralG: Double
    var gpsAccuracyP50: Double
    var gpsAccuracyP95: Double
    var maxLocationGap: TimeInterval
    var motionSampleCount: Int
    var motionDropRate: Double

    @Attribute(.codable) var calibration: MountCalibration?
    @Attribute(.codable) var startPlace: PlaceMeta?
    @Attribute(.codable) var endPlace: PlaceMeta?
    @Attribute(.codable) var viaPlaces: [PlaceMeta]
    var geocodePending: Bool

    @Relationship(deleteRule: .cascade) var markers: [Marker]
    @Attribute(.codable) var sections: [DriveSection]   // V1.1 区間解析（派生データ）
    var sectionsVersion: Int                            // SectionDetector.version 未満なら遅延で再計算
}

@Model final class Marker {
    var id: UUID
    var kind: MarkerKind               // sync / mark / highlight
    var elapsed: TimeInterval
    var date: Date
    var label: String?
}

struct PlaceMeta: Codable {
    var name: String?                  // POI / 道路名（取れないことが多い）
    var locality: String?              // 市区町村
    var subLocality: String?
    var administrativeArea: String?    // 都道府県
    var fullAddress: String?
    var mapItemIdentifier: String?     // MKMapItem.Identifier.rawValue
    var latitude: Double
    var longitude: Double
    var role: PlaceRole                // start / end / maxAltitude / peakG
}

struct MountCalibration: Codable {
    var rotation: [Double]             // 3x3 device→vehicle
    var method: String                 // auto / manual
    var confidence: Double
    var calibratedAtElapsed: TimeInterval
}
```

### 4.3 データ量（1 時間あたり）

| ストリーム | レコード | レート | 1 時間 |
|---|---|---|---|
| Location | 72 B | 1 Hz | 0.26 MB |
| Altitude | 16 B | ~1 Hz | 0.06 MB |
| Motion（device motion） | 72 B | 25 / 50 / 100 Hz | 6.5 / 13.0 / 25.9 MB |
| Motion（加速度のみ） | 20 B | 10 Hz | 0.72 MB |

| プリセット | 合計 / 時間 | 2 時間 | 100 走行（1.5 h 平均） |
|---|---|---|---|
| GPS Only | 0.3 MB | 0.6 MB | 0.05 GB |
| Eco（加速度 10 Hz） | 1.0 MB | 2.1 MB | 0.16 GB |
| Vlog 25 Hz | 6.8 MB | 13.6 MB | 1.0 GB |
| Logger 50 Hz | 13.3 MB | 26.6 MB | 2.0 GB |
| Lab 100 Hz | 26.2 MB | 52.4 MB | 3.9 GB |

JSON Export はバイナリの約 2.5〜3 倍（S6 で実測。当初見込みの 8〜10 倍は過大だった）。CSV 10 Hz 統合出力は約 4 MB/h。アーカイブ時に LZFSE で Motion は 40〜60% 縮む。制約はサイズより書き込み頻度・CPU・発熱。


### 4.4 LZFSE アーカイブ（V1.1）
- 終了済み（stopped / recovered）のセッションのストリームを `<name>.bin.lzfse` に置き換える。形式: 16 B ヘッダ（magic "DSLZ"・version・元サイズ）+ 元ファイル全体（32 B ヘッダ込み）をバイトシャッフルしてから LZFSE。可逆で、読み手には `SessionFiles.streamData(_:)` が元のバイト列を返す（Replay・書き出し・統計・品質はすべてこの入口を通る）。
- バイトシャッフル: レコードをバイト位置ごとのプレーンに並べ替える（vImage の 90° 回転、プレーン内は逆順）。実機 50 Hz の motion.bin は LZFSE だけだと元の 82〜88%、シャッフル後は 57〜68%。スクリプト走行の 2 時間 Logger は 28 MB → 7.8 MB。アーカイブ済み 2 時間ログのオープンは Mac で約 20〜40 ms。
- 手順（クラッシュ安全）: 一時ファイルに書く → 展開して元と一致を検証 → fsync → rename → 全ストリーム完了後にディレクトリ fsync → manifest に `archivedAt` → 最後に `.bin` を削除。両方あるときは生ファイルを優先し、次回の実行で `.tmp` の削除と不一致アーカイブの作り直しをする。
- アーカイブ済みのストリームには追記できない（`SampleWriter` が拒否）。対象は記録中でないセッションだけ。
- 設定「古いセッションを圧縮」（オフ / 7 / 30 / 90 日、既定 30 日）で、起動時と STOP 後に 1 件ずつ実行（記録中・低電力モード中はしない）。詳細画面のメニューから「今すぐ圧縮」も可能。
---

## 5. Raw と派生データの棲み分け

```
Capture（Raw: 端末座標系・未平滑・プリセットで Hz だけ選ぶ）
   ├─► Logger 成果物 = Raw そのもの（JSON lossless / GPX / Quality レポート）
   └─► VlogTrack（派生・いつでも再生成可能）
         - 30 fps に一定周期リサンプル（GPS は補間、course は circular）
         - Calibration 適用済み車両座標 G
         - 表示用平滑化（速度 3〜5 sample 移動平均、G は低域通過）
         - SYNC マーカー基準の t=0 オフセット
         - CSV / 将来の動画 HUD レンダラーの入力
```
- 取得段階で間引かない。Vlog 用は派生物として扱い、Export 画面で「Logger」「Vlog」タブに分ける。
- `ReplayTelemetryFrame` は VlogTrack と同じ合成ロジック（`TelemetryInterpolator`）から生成する。

---

## 6. Telemetry パイプライン

```
LocationSource ─┐
MotionSource   ─┼─► TelemetryEngine (nonisolated actor) ─► SampleWriter (actor) ─► *.bin
AltimeterSource─┘         │
                          ├─► LiveTelemetry (@Observable, @MainActor, 10 Hz throttle) ─► HUD
                          ├─► LiveActivityUpdater (2 s)
                          ├─► RecordingWatchdog
                          └─► RunningStatistics
```
- `RecordingController` が唯一の状態管理元。状態: `idle → preparing → recording → stopping → finalizing → stopped`、例外: `recording → interrupted → recovered | discarded`。
- センサーコールバックは MainActor に乗せない。HUD への反映は 10 Hz に間引く。
- Core Location は開始直後にキャッシュ済みの古い fix を渡してくる（実機で 2 分前・別の場所）。そのラン（START / 再開）の開始より 2 秒以上古い fix は記録しない（ルート始点の飛び・距離の過大を防ぐ。ウォッチドッグの「fix あり」にも数えない）。

---

## 7. Mount Calibration
**記録中（`MountCalibrator`、HUD 用）**
1. 「上」: 重力が 3 秒間安定（移動平均から 3° 以内、衝撃 0.6 G 未満）したときの平均重力の逆向き。
2. 「前」: 最初の発進（GPS speed が 0 → 15 km/h 超、かつ userAcceleration の水平成分が 0.15 G 超）で加速方向を仮決め。
3. GPS 照合: GPS 区間ごとの水平加速度と GPS の前後（dv/dt）・横（v × ヨーレート）加速度から、「上」まわりの回転角を 2 次元 Procrustes で推定（Σ GPS 加速度² ≥ 0.3 g² で採用）。発進なしでも決まり、90° / 180° の誤りも直る。confidence = 一致度（0…1）。
4. 取り付け状態の変化: 重力が「上」から 15°（Eco は 25°）以上離れた状態が 2 秒続いたら破棄して 1 から（events に `mountChanged`）。新しい「上」が直前のマウント（最大 4 件）と 5° 以内なら同じマウントとして即復元（ホルダーごと揺れた・外して戻した）。
5. Recording 画面に「90° 回転」の手動補正を用意（次の取り付け状態の変化まで自動推定より優先）。

**STOP 後（`MountSolver`、保存・Replay・Export 用）** — 記録中の推定は過去しか見られず、START 時に手に持っていた数秒やホルダー外の区間に引きずられる（2026-09-30 の初回実車で全区間の横 G・ロール・ピッチが誤っていた）。
1. 1 秒ごとの重力を集計し、±10° 以内に最も多くの秒が集まる向きをマウントとし、その平均重力から「上」。
2. マウントの向きの区間だけで GPS 照合（上の 3.）を行い「前」を決める。
3. 補間（`TelemetryInterpolator`）は前後 ±1.5 秒ずっと「上」から 15° 以内のときだけモーション由来の G・ロール・ピッチを使う（`hasMotionG`）。外れている間は横 G = GPS 推定、他は 0、速度のモーション補助もしない。
4. `SessionFinalizer.ensureSections` が区間解析と一緒に実行し（`SectionDetector.version` 2）、セッションと manifest の calibration を置き換える。手動補正は solver の confidence < 0.5 なら残す。
5. Peak G = コーナー区間内の最大横 G（モーション由来を優先）。ホルダーの調整や手で持った瞬間を拾わない。地名の peakG 地点もこの時刻。

---

## 8. 地名メタ（STOP 時）
```
SessionFinalizer
  1. 代表点: 開始 / 終了 / 最高標高 / 最大横G（最大 6 点）
  2. MKReverseGeocodingRequest を各点に実行（MapKit, iOS 26+）
  3. PlaceMeta として保存。失敗時は geocodePending = true
  4. 自動タイトル: "前橋市 → 沼田市" / 出発≒到着なら "前橋市 · Loop"
     titleIsUserEdited == true なら上書きしない
  5. NWPathMonitor でネット復帰時に pending を再試行
```
- 通称（例: "赤城峠"）は逆ジオコーディングでは取れない。ユーザー編集で上書きする前提。
- JSON Export に `places` ブロックとして含める。

---

## 9. バックグラウンド動作

### 9.1 前提
- `UIBackgroundModes = [location]`。位置更新を購読している間はプロセスが起き続け、Core Motion / Altimeter / 書き込み / Live Activity 更新も継続する。
- 権限は **While Using で十分**（START はフォアグラウンド）。Always は V1.1 の「堅牢モード」でのみ要求。
- 画面ロックはバックグラウンドと同じ扱い。

### 9.2 止まるケース
| ケース | 対処 |
|---|---|
| ユーザーが強制終了 | 起動時 Recovery シート |
| システムによる終了 | 2 秒 flush + Recovery |
| GPS 長時間途絶（トンネル）→ サスペンド | Watchdog 2 段目（デッドマンスイッチ） |
| 低電力モード | Home のセンサー状態に警告 |
| バックグラウンドで START | 不可。UI で防ぐ |

### 9.3 RecordingWatchdog（2 段）
**1 段目（プロセス生存中）**
```
最終 Location からの経過
   > 15 s  → HUD / Live Activity に GPS SEARCHING（通知なし）
   > 60 s  → Live Activity を alertConfiguration 付きで更新
   > 120 s → 即時ローカル通知「GPS を 2 分間受信できていません。記録は継続中です」
最終 Motion からの経過 > 10 s → 同様の段階通知
```
**2 段目（デッドマンスイッチ）**
```
START: UNTimeIntervalNotificationTrigger(180 s), id = "recording.deadman"
Location / flush ごと（15 s に 1 回に間引く）: 同 id で再登録して延期
STOP: removePendingNotificationRequests
```
サスペンド・クラッシュ・強制終了のどれでも、最終延期から 180 秒後に OS が単独で通知。通知タップでアプリ復帰 → `state == .recording` のセッションを再開・同じファイルに追記。

### 9.4 events ストリーム
`events.bin` に `gpsLost / gpsResumed / motionStalled / motionResumed / appDidEnterBackground / appWillEnterForeground / watchdogFired / resumedFromNotification / calibrationUpdated / thermalStateChanged / lowPowerModeChanged / carPlayConnected / carPlayDisconnected / screenOn / screenOff / batterySnapshot（5 分ごと: 残量・充電状態・thermal）/ batteryLowSuggested / marker / sessionResumed / autoResumed` を elapsed 付きで記録。Quality 画面と JSON Export に出す。`marker` の aux はマーカーの種類（0 = MARK、1 = SYNC、2 = HIGHLIGHT。永続化されるので番号は変えない）。

### 9.5 堅牢モード（V1.1）
- 設定 → 記録 →「堅牢モード」（既定オフ）。オンにすると位置情報の「常に」許可を求める（`NSLocationAlwaysAndWhenInUseUsageDescription`）。未許可なら設定アプリへのリンクを出す。
- 有効（設定オン + Always）なとき、記録中は Significant Location Change を監視する（`RobustMode`）。プロセスが走行中に落ちても（クラッシュ・メモリ不足）、iOS がアプリをバックグラウンドで再起動する。STOP で監視を止め、記録を継続しない起動でも止める（アイドル時に再起動され続けないため）。
- バックグラウンド起動では `RecordingController.autoResume()` が最新の未完了セッションを UI なしで継続する。条件は `resumeDecision`: 同じ起動（uptime が巻き戻っていない）かつ最後のサンプルから 30 分以内（実時間。uptime はスリープ中止まるため）。`sessionResumed` と `autoResumed`（値 = 途切れた秒数）を events に記録。フォアグラウンド起動は従来どおり復旧シート（同じ判定を使う）。
- Live Activity: 継続するセッションの Live Activity は起動時の後片付けから外して引き継ぐ。バックグラウンドで新規作成を拒否されたら、次にアクティブになった時に作り直す。
- `liveUpdates` バックエンドは `CLServiceSession(.always)` で開く。再開時は配信済みのデッドマン通知を消す。
- **未検証（実車）**: 実際に iOS が再起動して継続するか・所要時間、ユーザーのスワイプ終了後はどうなるか、STOP 後に再起動されないこと。結果をここに追記する。

---

## 10. Live Activity（ActivityKit）
- 1 つの `DriveActivityAttributes` から Lock Screen / Dynamic Island（compact 縦・横・minimal・expanded）/ StandBy / `.small`（CarPlay Dashboard・Watch）を描く。
- `ContentState = { elapsed, speedKmh, distanceKm, gpsAccuracyM, lateralG, status }`。更新は 2 秒間隔。
- `isDynamicIslandLimitedInWidth` で横向き compact は「REC ドット + 速度」に縮退。
- `.supplementalActivityFamilies([.small])`、`activityBackgroundTint(.black)`。
- `LiveActivityIntent` で MARK / STOP をロック画面と expanded から実行。
- 言語はアプリ内設定に従う（§13）。

### 10.1 Apple Watch（MVP: Watch アプリなし / V1.1: W3 Watch アプリ）
- **W1 Smart Stack 表示**: iPhone の Live Activity は watchOS 11+ で Watch アプリなしに Smart Stack / 文字盤へ表示される。Watch 側は Dynamic Island の compact / expanded の内容から描かれるため、compact（REC + 経過 / 速度）と expanded を Watch でも読める密度で作る。`.small` family は CarPlay と共通。
- **W2 Double Tap で MARK**: MARK ボタンに `.handGestureShortcut(.primaryAction)` を付与し、ハンドルを握ったまま指の Double Tap（Series 9 / Ultra 2 以降）で MARK できるようにする。watchOS 27 の Single Tap でも Smart Stack から選択可能。
- **検証済み（2026-09-29、Series 9）**: Smart Stack の MARK は iPhone の `LiveActivityIntent` に届く。ただし 1 回の操作が 0–0.1 秒差で 2 回届くため、Live Activity 経由の MARK は 0.5 秒以内の重複を無視する。Watch 側の反映は約 1 秒（Watch ↔ iPhone の往復）。Live Activity 経由の MARK の source は区別できず `liveActivity`。
- **W3 Watch アプリ（V1.1）**: 単一ターゲットの watchOS 27 アプリ（`Watch/`、iPhone アプリに埋め込み、パッケージはリンクしない）。メッセージ型は `WatchShared/`（アプリと共有）。
  - iPhone 側 `WatchLink`: フェーズ変化で application context、記録中は到達可能なとき 1 Hz で状態を送る。Watch のコマンドを ID で重複排除して実行し、ack を返す。
  - 画面: 記録中は REC + 経過・速度・大きな MARK（Double Tap = `handGestureShortcut(.primaryAction)`、MARK 件数バッジ）・STOP（確認あり）。待機中は「記録していません」、堅牢モードが有効なら START。ack で成功 / エラーの触覚。iPhone のアプリ内言語に従う。
  - MARK は `source = watch`、elapsed は iPhone の受信時刻、events の value に Watch で押した時刻（UNIX 秒）。キューに溜めない（遅れて届くと時刻がずれるため）。
  - START は堅牢モードが有効（Always + 正確な位置）なときだけ。許可ダイアログは出さない。SYNC と HIGHLIGHT は iPhone のみ（MARK 件数バッジも MARK だけを数える）。
  - 実機（2026-09-30、Series 9 + iPhone 16 Pro Max）: MARK 4 件すべて `source = watch` で記録、重複なし、1 秒以内の連打も取りこぼしなし。押下時刻 − 受信時刻は −360〜−322 ms（Watch と iPhone の時計差を含むため絶対値は測れないが、ばらつき 38 ms）。

---

## 11. 画面構成（モック準拠）

| # | 画面 | 要点 |
|---|---|---|
| 1 | Home / Ready | センサー状態（GPS 精度・Precise・Motion Hz・気圧・給電・背景許可）、START、最近のセッション、タブ（Record / Sessions / Quality） |
| 2 | Recording HUD（縦） | 速度 132pt、ALT / COURSE / DIST、G メーター、MARK / HIGHLIGHT / SYNC（3 等分、アイコンを文字の上に積む）、STOP（全幅・長押し）。ミニ Map なし |
| 8 | Recording HUD（横） | 同じ情報を 3 カラム配置。横幅クラスで `VStack` / `HStack` を切り替える 1 つの View。ボタンは MARK / HIGHLIGHT / SYNC / STOP を 4 等分（iPad も同じ 4 等分、キーボードは M / H / S） |
| 3 | Sessions | `@Query(sectionBy:)` で月別、ルートサムネ、RECOVERED バッジ |
| 4 | Session Detail | Map（開始 / 終了 / マーカー）、6 指標、Log Quality 行、Replay / Export |
| 5 | Timeline Replay | Map 追従、速度スパークライン（Swift Charts）、スライダー、マーカー（SYNC / MARK / HIGHLIGHT）ジャンプ、再生速度 |
| 6 | Lock Screen Live Activity | REC・経過・速度・距離・GPS、MARK / STOP |
| 7 | Crash Recovery Sheet | item-binding の alert / sheet |
| 9 | StandBy | 200% 拡大、ボタンなし |
| 10 | Dynamic Island / CarPlay small | 5 パターン |
| — | Quality（Debug） | サンプル数・平均間隔・最大ギャップ・精度 P50/P95・Motion 実効 Hz・欠落・thermal・**電池消費 %/h（画面 ON / OFF 別）**・events |
| — | Settings | プリセット（5 種、電池・データ量の目安付き）、単位、言語、堅牢モード（V1.1） |

デザイン: ダーク単一テーマ、数値は等幅（SF Mono 相当）、アクセントは琥珀 1 色 + REC 赤 + GPS 良好の緑。Liquid Glass はタブバー・ボタンのシステム標準に任せ、HUD 本体はフラットな黒。

マーカー: MARK = ブックマーク（白）、SYNC = カメラ同期の基準（緑）、HIGHLIGHT = 見どころ（琥珀。Vlog で前方カメラに切り替える瞬間）。HIGHLIGHT は MARK と同じ確認表示（チェック + 触覚）だけで、音やフラッシュは出さない。Live Activity と Watch には MARK だけを置く。Sessions の一覧はマーク件数と見どころ件数を別々に出す。

---

## 12. Replay / 補間 / Export
- `TelemetryInterpolator`: Location は線形（course は circular）、Motion は最近傍または線形。共通 API。
- **速度のモーション補助（V1.1）**: fix 間の速度は、キャリブレーション済みの前後加速度を fix a から積分し、fix b での差分を区間内で線形に配分して求める（`v = max(0, va + ∫a + e·(t−ta)/T)`）。両端の fix で GPS 速度と一致し、区間内の一定バイアスは消える。キャリブレーションなし・confidence < 0.5・モーションなし（GPS Only）・fix 間隔 > 3 s（トンネル）・モーション欠落 > 0.25 s・|e|/T > 2 m/s² のときは線形補間。停車（両端 < 0.3 m/s）は 0。Eco は区間ごとの重力推定（前後 2 s の平均、|g| が 1 ± 0.03 のときのみ）。Replay・CSV・GPX に適用（`Options.speedFusion`）。
- `ReplayTelemetryFrame { time, lat, lon, speed, altitude, course, lateralG, longitudinalG, verticalG, roll, pitch, yaw, gpsAccuracy, hasFix, hasMotionG }`。`hasMotionG` = false はキャリブレーションなし、または端末がマウント外（§7）。速度のモーション補助も両端の fix がマウント内のときだけ。
- **区間解析（V1.1）**: `SectionDetector`（DriveReplay、純関数）が 5 Hz の解析フレームから `DriveSection`（corner / climb / descent / stop）を作る。
  - corner: |横 G| ≥ 0.15 で開始、同符号で ≥ 0.08 の間継続（ヒステリシス）。1.5 s 以上・ピーク時 15 km/h 以上・方位変化 15° 以上。同じ向きで 1 s 未満の隙間は結合。左右・ピーク G・進入 / 脱出 / 最低速度。
  - stop: fix の速度 < 1 km/h が 10 s 以上（fix 間隔 > 5 s で途切れる → トンネルは停止にならない）。
  - climb / descent: 走行距離 50 m ごとの高度（3 ビン平均）で、直近 200 m の勾配が ±3% 以上の連続区間。500 m 以上かつ |Δ高度| 15 m 以上。
  - STOP / 復旧時の `SessionFinalizer.ensureSections` で計算して `DriveSession.sections` に保存（同時に `MountSolver` によるキャリブレーションの置き換え、Peak G とその時刻、manifest の開始時刻・終了時刻の修復 — §7）。古いセッションは詳細・Replay・書き出し時に遅延計算。しきい値を変えたら `SectionDetector.version` を上げる（2 = V1.1.1）。
- Export
  - **JSON** = Master（lossless、session / places / markers（kind = `sync` / `mark` / `highlight`） / **sections**（V1.1、派生） / events / location / motion / altitude）
  - **CSV** = Vlog（VlogTrack 30 fps、または 10 Hz 選択可）
  - **GPX** = 互換（`<trkpt>` + extensions: speed / course / hAcc）。マーカーは `<wpt>`（実時刻付き）で、SYNC は時刻順に「SYNC 1」「SYNC 2」…と番号を付ける（カメラを撮り直したときに、動画ファイルごとの基準を VLOG 側で選べるように）
  - `ShareLink` / `UIActivityViewController`

---

## 13. ローカライズ（日本語 / 英語）
- **String Catalog（`Localizable.xcstrings`）**に ja / en。開発言語は en、Base は使わない。
- 既定は OS 言語。**アプリ内の言語設定**（System / 日本語 / English）を `AppStorage("appLanguage")` に保持し、OS 言語に依存せず切替可能。再起動不要。
- 実装
  - `@Observable AppLanguage { var locale: Locale; var bundle: Bundle }`
  - SwiftUI: ルートで `.environment(\.locale, appLanguage.locale)`。`Text` の String Catalog 参照はこの locale で解決される。
  - 非 View コード（通知文・Export ラベル・自動タイトル）: `String(localized:table:bundle:locale:)` に `appLanguage` を渡す。
  - Live Activity / Widget: `ContentState` に `languageCode` を含め、Widget 側でも `.environment(\.locale, …)`。
  - `AppleLanguages` の UserDefaults 書き換えは再起動が必要なので使わない。
- 数値・単位は `Measurement` + `MeasurementFormatter` を locale 付きで。数字は両言語とも Latin 数字・等幅。
- 日本語 UI でも HUD のラベル（ALT / COURSE / DIST / LAT G）と操作ボタンの表記（START / MARK / HIGHLIGHT / SYNC / STOP）は英語のまま。START の下の補足（「ドライブを記録」）、アクセシビリティのラベル、説明文・設定・通知・タイトルは翻訳。

---

## 14. 技術スタック

| 項目 | 選定 |
|---|---|
| 言語 / ツール | Swift 6.4、Xcode 27.2、`.xcproj`（JSON プロジェクト形式）を採用 |
| UI | SwiftUI、Observation（`@Observable`）、Swift Charts |
| 並行性 | App ターゲット: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` + Approachable Concurrency（Xcode 既定）。**Sensors / Recording / Storage / Replay / Export はローカル SwiftPM パッケージに分離し `nonisolated` 既定** |
| 位置 | Core Location（`CLLocationManager` と `liveUpdates` を Test B で比較）、`CLServiceSession` |
| Motion | Core Motion `CMMotionManager`（≤100 Hz） |
| 気圧 | `CMAltimeter` |
| Map | MapKit for SwiftUI、`MapPolyline`、`MKReverseGeocodingRequest` |
| 永続化 | SwiftData（メタ）+ 追記型バイナリ（サンプル） |
| 背景 | `UIBackgroundModes: location`、`CLBackgroundActivitySession`、ActivityKit |
| 通知 | `UserNotifications`（Watchdog）、Live Activity alert |
| Export | Foundation / XMLCoder 不使用の手書き GPX |
| テスト | Swift Testing。センサーは protocol + Fake。記録済み `.bin` を流し込むリプレイテスト |
| ローカライズ | String Catalog、ja / en |

---

## 15. プロジェクト構成
```
DriveScope/
├── DriveScope.xcproj
├── App/                         DriveScopeApp, RootTabView, AppState, AppLanguage
├── Features/
│   ├── Home/
│   ├── Recording/               RecordingView (portrait/landscape), GMeterView, TelemetryValue
│   ├── Sessions/
│   ├── SessionDetail/
│   ├── Replay/
│   ├── Quality/
│   ├── Settings/
│   └── Recovery/
├── LiveActivity/                DriveActivityAttributes, DriveActivityWidget (extension target)
├── Packages/
│   ├── DriveDomain/             Session, Marker, Sample structs, TelemetryFrame, Units, PlaceMeta
│   ├── DriveSensors/            LocationSource, MotionSource, AltimeterSource (+ CL/CM impls, Fakes)
│   ├── DriveRecording/          RecordingController, TelemetryEngine, SampleWriter, Watchdog, MountCalibrator, SessionFinalizer
│   ├── DriveStorage/            SessionStore (SwiftData), TelemetryFileStore (bin I/O), Recovery, Manifest
│   ├── DriveReplay/             TelemetryReader, Interpolator, ReplayPlayer, Statistics, VlogTrack
│   └── DriveExport/             JSONExporter, CSVExporter, GPXExporter
├── Resources/                   Localizable.xcstrings, Assets
├── docs/                        PLAN.md, TESTING.md（実車テスト記録）
└── Tests/                       各パッケージの Swift Testing + Fixtures/*.bin
```

---

## 16. スプリント計画

| Sprint | 内容 | Exit criteria |
|---|---|---|
| **S0 Bootstrap** | `.xcproj` 作成、Bundle ID / Team、パッケージ分割、Background Mode、権限文字列、String Catalog（ja/en）、AppLanguage、CI（ビルド + テスト） | 実機起動、言語切替が動く |
| **S1 縦切り** | 権限フロー（Precise 判定）、`LocationSource`（両実装）、`RecordingController`、`location.bin` 書込、Home + Recording HUD（縦・横）+ STOP、Sessions 一覧、Detail の Map ルート | 実車で START → 走行 → STOP → 軌跡表示 |
| **S2 信頼性** | `CLBackgroundActivitySession`、Live Activity（全サーフェス、Watch Smart Stack 含む）、MARK の Double Tap 対応、2 秒 flush、Recovery、**RecordingWatchdog（2 段）**、**events ストリーム**、Quality 画面 | 画面 OFF 30 分でルート欠落ゼロ、強制終了後に復旧、通知が届く、Watch の Double Tap で MARK が iPhone に記録される |
| **S3 Motion + プリセット** | `MotionSource`（device motion 25/50/100 Hz と加速度のみ 10 Hz の 2 実装）、`motion.bin`（2 形式）、`MountCalibrator`（加速度のみでも動作）、G メーター、GPS 推定横 G、MARK / SYNC、5 プリセット設定、電池記録（batterySnapshot）と %/h 算出、残量低下時の提案 | 30 分で Motion 欠落率 < 0.1%、横 G の符号がコーナーで正しい、全プリセットで記録・再生できる |
| **S4 Altimeter + 統計 + 地名** | `altitude.bin`、baseline、6 指標、`SessionFinalizer`（逆ジオコーディング・自動タイトル）、rename / delete | 峠で Gain が妥当、タイトルが自動生成される |
| **S5 Replay** | `TelemetryReader`（mmap）、`Interpolator`、`ReplayTelemetryFrame`、Replay 画面、Swift Charts | スライダーで Map と HUD が同期、2 時間ログでも即開く |
| **S6 Export** | JSON / CSV（VlogTrack）/ GPX、ShareLink、Export 画面の Logger / Vlog タブ | Files / AirDrop / Mac で開ける |
| **S7 仕上げ** | Settings、Liquid Glass 調整、iPad / リサイズ対応確認、実車テスト A〜D、docs/TESTING.md | Definition of Done 全項目 |

各スプリントは「1 コミット単位で動く状態」を保つ。S1 終了時点で実車テストを 1 回挟む。

---

## 17. 実車テスト計画
| Test | 条件 | 確認 |
|---|---|---|
| A 静止 | 10 分停車 | GPS ドリフト、距離が増えない、G ノイズ、高度ドリフト |
| B 市街地 | 20〜30 分 | 信号停止、建物誤差、背景 / ロック継続、`CLLocationManager` vs `liveUpdates` 比較 |
| C 峠 | 30〜60 分 | 高低差、横 G、course、GPS vs 気圧高度、Calibration、トンネル時の Watchdog |
| D 長時間 | 2 時間以上 | memory、storage、battery、thermal、欠落、Recovery |
| E 電池比較 | 同一ルート 60 分 × 3 回（GPS Only / Eco / Logger）、画面 OFF・非充電 | プリセット別 %/h を実測し §2.2.2 の推定値を置き換える。Eco の G と Logger の G の差、GPS 推定横 G の誤差も比較 |

結果は `docs/TESTING.md` に日付・端末・OS・プリセット付きで記録する。

---

## 18. 設計上の最重要ルール
1. Raw sensor data を可能な限り残す（端末座標系・未平滑）
2. 表示 / Vlog 用フィルタと保存用データを分離する
3. GPS / Motion / Altimeter / Events を独立した time-series として扱う
4. すべてを session elapsed time と絶対時刻の両方に変換可能にする
5. 固定 1 Hz GPS を前提にしない
6. 背景動作と停止検知を初期スプリントから検証する
7. UI より先にロギングの信頼性を作る
8. GPX を内部マスター形式にしない。JSON を lossless export とする
9. Replay Engine（Interpolator / Frame）を将来の Video HUD Engine として再利用する
10. サンプル本体を SwiftData に入れない

---

## 19. V1.1 候補
- 堅牢モード（Always 権限 + Significant Location Change による自動復旧） — ✅ 実装（§9.5、実車での再起動確認は未）
- Motion 補助による速度の 10 Hz 補間（GPS 1 Hz の間を加速度積分で埋める） — ✅ 実装（§12）
- Replay 区間解析（コーナー・登り / 下り）→ `sections[]` — ✅ 解析・保存・JSON（§12）
- **Apple Watch コンパニオンアプリ（W3）** — ✅ 実装（§10.1。MARK は実機確認済み、START は実機未確認）
  - 画面: 大きな MARK（`handGestureShortcut(.primaryAction)`）、REC 状態・経過・速度、STOP
  - 通信: `WatchConnectivity`（Watch からの送信で iPhone アプリがバックグラウンドで起動・処理）
  - MARK 時の触覚フィードバック。Watchdog のローカル通知は OS が自動で Watch に転送
  - **START は堅牢モード（Always 権限）時のみ**（iPhone をバックグラウンドから記録開始させるため）
  - **SYNC は iPhone のみ**。Watch → iPhone の通信遅延（100〜500 ms 程度でばらつく）は動画同期基準に不十分。Watch 起点の操作は Watch 時刻と iPhone 受信時刻の両方を保存し、MARK（±1 s で十分）用途に限定
- LZFSE アーカイブ — ✅ 実装（§4.4）
- **CarPlay Driving Task アプリ — シミュレータ検証のみ**
  - **権限（`com.apple.developer.carplay-driving-task`）は申請しない**。CarPlay 権限は Apple 管理の権限で、個人利用でも実機（Mac の CarPlay Simulator アプリ経由・実車とも）では承認なしに動かない。
  - Xcode の iOS シミュレータ + CarPlay 外部ディスプレイでは、`.entitlements` にキーを書くだけで表示できる見込み（開発者報告ベース。着手時に最初に確認し、不可ならこの項目は中止）。
  - 試作範囲（テンプレートのみ）: グリッドで START / STOP / MARK / SYNC、情報テンプレートで REC 状態（経過・距離・GPS 精度）、直近セッション一覧、iOS 27 の Voice Control テンプレート（オーバーレイ）で音声 MARK。
  - 独自描画（速度 HUD・G メーター・地図）と走行中の Replay はテンプレートの制約上不可。
  - 位置づけ: 実車では使えないため、UI・操作フローの検証と将来の申請判断の材料とする。**実車での CarPlay 対応は MVP の Live Activity `.small`（CarPlay Dashboard、権限不要）のみ**。
  - 承認のない権限を実機ビルドの entitlements に含めると署名エラーになるため、CarPlay 用 entitlements はシミュレータ向けのビルド構成（`[sdk=iphonesimulator*]` 条件付き設定）にだけ入れる。
- **CarPlay 接続で自動 START**（オプション）
  - 接続・切断を検知して events に記録（`carPlayConnected / carPlayDisconnected`、これは MVP の events に含めてよい）
  - 自動 START はバックグラウンドからの開始になるため Always 権限が必要 → 堅牢モードとセット

## 19.1 V2 検討項目
- **Apple Watch 心拍（W4）**
  - Vlog HUD に運転者の心拍を表示する用途
  - Watch 上で `HKWorkoutSession` を実行し iPhone へミラーリング受信（iOS 17+）、`heartrate.bin`（1 Hz × 16 B、容量は無視できる）
  - 個人利用のため App Review（HealthKit の用途制限）は対象外。判断材料は実装コストのみ（Watch アプリ + `HKWorkoutSession` + ミラーリング + HealthKit 権限）。
  - HealthKit 権限（Capability）は Apple 承認不要で、個人の開発チームでも実機で使える。
  - 自分用でも守る設計: Health アプリに運転をワークアウトとして保存しない終了処理（Activity リング等を汚さない）、Export 時の心拍データはオプトイン（動画・ファイル共有時に意図せず出さない）
  - 腕の加速度は車両 G と無関係、Watch の GPS は iPhone より良くないため、どちらも採用しない

## 20. 参考
- WWDC26: SwiftUI guide https://developer.apple.com/wwdc26/guides/swiftui/
- WWDC26 223 Live Activities essentials https://developer.apple.com/videos/play/wwdc2026/223/
- WWDC26 274 What's new in SwiftData https://developer.apple.com/videos/play/wwdc2026/274/
- WWDC24 What's new in location authorization https://developer.apple.com/videos/play/wwdc2024/10212/
- MKReverseGeocodingRequest https://developer.apple.com/documentation/mapkit/mkreversegeocodingrequest
- CLBackgroundActivitySession https://developer.apple.com/documentation/corelocation/clbackgroundactivitysession
- CMMotionManager https://developer.apple.com/documentation/coremotion/cmmotionmanager
