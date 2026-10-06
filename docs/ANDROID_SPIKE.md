# Android 試作(S0 スパイク)

DriveScope を Android(Pixel 7 / Android 16)へ追いかけて対応するための試作の記録。ブランチ `feature/android-s0-spike`
(main にはマージしない)。前提: 自分用の APK、記録データは iOS と同じ形式で今の Vlog 制作の流れに流す、iOS が中心。

決めること: ① センサーの決まりを iOS の形式にどう合わせるか ② 中核(DriveKit)を Swift のまま共有するか Kotlin に移植するか
③ 地図(Google Maps / MapLibre)④ 画面 OFF で 50 Hz を欠落なく記録できるか。

## 構成

| 場所 | 中身 |
|---|---|
| `Android/` | Gradle プロジェクト(AGP 9.3.2、Kotlin 2.2、Compose BOM 2026.08、minSdk 34、target 37)。`com.miquottty.drivescope` |
| `Android/app/.../probe/` | センサー確認画面(衛星・位置・モーション・向きの確認) |
| `Android/app/.../recording/` | 記録(位置情報タイプのフォアグラウンドサービス + wake lock)、iOS 形式の `.bin` と `manifest.json` の書き込み |
| `Packages/DriveKit/Sources/drivekit-cli` | Mac 側の確認ツール。取り出したセッションのフォルダをアプリと同じ処理で集計・書き出しする |

```bash
cd Android && JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew assembleDebug
~/Library/Android/sdk/platform-tools/adb install -r app/build/outputs/apk/debug/app-debug.apk
~/Library/Android/sdk/platform-tools/adb pull /sdcard/Android/data/com.miquottty.drivescope/files/Sessions <dir>
scripts/xc.sh swift run --package-path Packages/DriveKit drivekit-cli quality <dir>/<UUID>
scripts/xc.sh swift run --package-path Packages/DriveKit drivekit-cli export json <dir>/<UUID> --out <dir>
```

## 確認ツール(drivekit-cli)の検証

iPhone(nachoneko)の 2026-10-06「足利市 → 太田市」を端末から取り出して `export json` した結果を、アプリの書き出しと比較:
位置 1,811 行・モーション 103,973 行・高度 2,091 行・イベント・マーカー・区間 20・マウント補正がすべて一致。
要約は記録時間の丸め(1e-7 s)のみ差。地名(places)は MapKit が必要なので確認ツールでは出さない。

## センサーの決まり(Pixel 7 の実測)

| 項目 | Android | iOS 形式への変換 | 状態 |
|---|---|---|---|
| 加速度・重力の単位と符号 | m/s²、反力の向き(上を向いた軸が +9.81)。軸の向きは iOS と同じ(x 右・y 上端・z 画面の外) | 3 軸とも ×(−1 / 9.80665) で g、Core Motion の符号に | 確定。上向き置き: Android z +9.81 → iOS z −1.00、右側面を下: Android x −9.14 → iOS x +0.93(残りは傾き)、縦: y の符号も一致 |
| センサーの時刻 | `SensorEvent.timestamp` は elapsedRealtime(スリープ中も進む)基準 | 全ストリームをこの時計にそろえ、manifest の `startUptime` も同じ時計 | 確定(届くまでの遅れ 1〜7 ms) |
| 周期 | 50 Hz を指定すると 59.3 Hz。重力・重力除去の加速度(合成センサー)は 100 Hz を指定しても 59 Hz 止まり | 生の加速度を 200 Hz で受け取り 20 ms の格子に間引き、最新の重力を引いて「重力を除いた加速度」を作る | 確定(下の記録結果) |
| 位置の時刻 | `Location.elapsedRealtimeNanos` | unix 時刻 = 開始時刻 + (fix の elapsedRealtime − 開始) | — |
| 高度 | 楕円体高。Android 14 以降は平均海面からの高さも取れる | 平均海面からの高さを優先(iOS と同じ基準) | — |
| 気圧 | hPa。1 Hz を指定しても約 36 Hz で届き、1 件ごとのばらつき 1.2 m | 1 秒ごとの平均を 1 件(CMAltimeter と同じ間隔)。÷10 で kPa、相対高度は最初の値からの差 | 確定(ばらつき 0.37 m) |
| ジャイロ | rad/s、右手系(iOS と同じ定義) | そのまま | 実車で確認(ヨーの向きと GPS の方位の変化が合うか。MountSolver の結果でも分かる) |
| 姿勢 | 回転ベクトル(東・北・上の座標) | そのまま w, x, y, z で保存(Core Motion とは基準の向きが違う) | DriveKit は重力と加速度で補正するので影響は小さい見込み |
| 衛星の状態 | 見えている数・使っている数・信号の強さ・L5 が取れる | (iOS には無い情報。今後イベントや品質画面に使える) | 屋内では 0 個。屋外で確認する |

## 記録(画面 OFF)

位置情報タイプのフォアグラウンドサービス + PARTIAL_WAKE_LOCK。机上・画面 OFF で `drivekit-cli quality`:

| 回 | 方式 | モーション | 欠落 | 気圧 | 位置 |
|---|---|---|---|---|---|
| 1(210 s) | 重力除去の加速度センサーを基準に 20 ms 間引き、気圧そのまま | 49.97 Hz(17 / 34 ms が交互) | 15.4 %(34 ms を欠落と数える) | 36 Hz、静止で上昇 131.6 m | 0 件(GPS 専用、屋内) |
| 2(140 s) | 生の加速度 200 Hz を基準、気圧 1 秒平均、衛星が 5 s 来ない間は Wi‑Fi の位置も | **50.00 Hz**(間隔の中央値 21 ms、最大 31.6 ms) | **0.014 %** | 1.04 s 間隔、ばらつき 0.37 m、上昇 3.4 m | Wi‑Fi の位置(速度なし、±14〜100 m)が約 20 s ごと |

- DriveKit は Pixel のセッションを**変更なしで読めた**(`manifest.json` の追加項目 `platform` は無視される)。
- 屋内の位置の振る舞いは iOS と同じ(衛星をつかむ前は速度なしの位置)。DriveScope の衛星判定(`isSatelliteFix`)がそのまま効く。

## 地図

比較画面(`Android/app/.../map/MapScreen.kt`): iPhone の「足利市 → 太田市」(34:49)のセッションのフォルダを
`files/Imports` に push し、**リプレイのフレームは Android 上の DriveKit(Swift)の `TelemetryInterpolator` で作る**
(iOS の Replay と同じ補間・平滑化。10 Hz × 20,892 フレームを 180 ms)。

| | MapLibre + OpenFreeMap dark | MapLibre + 地理院 標準 | Google Maps |
|---|---|---|---|
| 表示 | ✓ 暗い地図、日本語の道路名(足利環状線など) | ✓(PMTiles の指定を Native 向けに書き換えて読み込む)。建物・神社・寺の記号まで | API キー待ち |
| 色 | 暗い。お店などの表示は少ない | 明るい。使うなら暗い配色に作り替える(スタイルは自由に変えられる) | — |
| リプレイ | ルート・再生済みの琥珀・車の矢印・ピン・追従・3D(60° 傾け)・32 倍速まで動作 | 同左 | — |
| キー | 不要 | 不要(出典表示のみ) | 必要 |

**結論: 地図は MapLibre(既定は OpenFreeMap の暗い地図、国土地理院は暗い配色に作り替えて選択肢に)。** 目的は Vlog 制作で、
動画の地図や 3D フライオーバーは書き出したデータから別に作るため、アプリ内でリアルな地図を完璧に再現する必要はない。
Google Maps(試作の `GoogleMapPane.kt`、Maps Compose 7.0.0)は保留し、#40 に残す。

地名(Android の `Geocoder`、Pixel では Google の住所データ): 開始「栃木県 / 足利市」、終了「群馬県 / 太田市」で **iOS(MapKit)と一致**。

## 中核の共有(Swift on Android)— 結論: ① Swift のまま共有する

環境: swiftly の Swift 6.4.0(シェルの設定は書き換えない。iOS は従来どおり Xcode 27.2 beta の Swift)、
Swift SDK for Android 6.4.0(チェックサム確認済み)、NDK r30(30.0.16248370、Android Studio で導入)。

```bash
Android/swift/build-bridge.sh   # DriveKitBridge をビルドし、strip して app/src/main/jniLibs/arm64-v8a へ(libc++_shared.so も)
```

| 対象 | 手を加えずに | 変更後 |
|---|---|---|
| DriveDomain(記録形式・サンプル) | ビルド可 | — |
| DriveSensors | ビルド可 | — |
| DriveStorage | SwiftData・LZFSE/vImage・Darwin の POSIX で失敗 | `#if canImport(SwiftData)` / `canImport(Accelerate)`(Android では圧縮は未対応エラー)/ `import Android` |
| DriveReplay | `import simd` で失敗 | simd の 4 関数(内積・長さ・正規化・外積)を `PortableSIMD.swift` で補う(Apple では本物の simd のまま) |
| DriveExport | 上の 2 つ次第 | ビルド可 |
| DriveRecording | MapKit・SwiftData | Android では使わない(記録は Kotlin 側) |

- DriveKit の変更は新規ファイルを含めて約 60 行。iOS のテスト 31 件・シミュレータ向けビルドは変わらず成功。
- JNI: `Android/swift/DriveKitBridge`(`@_cdecl` の 2 関数 `exportJson` / `quality`)+ Kotlin の `bridge/DriveKitBridge`。
  共通の書き出しは `SessionExporter.exportDerivingMetadata`(DriveExport)で、`drivekit-cli` と同じ関数。
- Android で踏んだ 2 点: Foundation の一時フォルダ(TMPDIR)が未設定 → アプリのキャッシュを設定 / `FileManager.copyItem` が
  共有ストレージからの権限コピーで拒否される → ファイルの中身だけをコピー。
- **結果: Pixel 7 上の Swift で書き出した JSON(1.7 MB)と、Mac の `drivekit-cli` の書き出しがバイト単位で一致。** 集計 + 書き出しで 48 ms。
- 大きさ: `libDriveKitBridge.so` は strip 後 54 MB(圧縮 21 MB)+ `libc++_shared.so` 9 MB。APK は 29 MB → 93 MB。
  大半は Foundation の国際化データと思われる。自分用なので許容。必要なら FoundationEssentials だけにして削る余地あり。

採用条件(計画): 囲む修正が小さい ✓ / APK に入れて Pixel で動く ✓ / macOS と結果が一致 ✓ / APK の増加 ✓(許容)。
→ **中核の計算・書き出しは Swift の DriveKit を Android でもそのまま使う。** Kotlin に移植しない。

## 試作の結論

| 問い | 結論 |
|---|---|
| センサーの決まり | 3 軸とも iOS = −Android / 9.80665。時計は elapsedRealtime に統一。生の加速度 200 Hz から 50 Hz の格子、気圧は 1 秒平均、衛星が来ない間だけ Wi‑Fi の位置 |
| 中核の共有 | **① Swift の DriveKit を Android でもそのまま使う**(JNI)。Kotlin に移植しない |
| 地図 | **MapLibre**。Google Maps は #40 |
| 画面 OFF の記録 | 位置情報タイプのフォアグラウンドサービス + wake lock で 50 Hz・欠落 0.014% |
| 残り(実車で確認) | ジャイロの符号、屋外での衛星の状態と最初の測位までの時間(iPhone と並走) |

## 本実装のスプリント案(Android は iOS を後追い)

役割分担: **センサー → .bin の記録と画面は Kotlin、計算・集計・補間・書き出しは DriveKit(Swift、JNI)**。

| スプリント | 内容 | 終わりの条件 |
|---|---|---|
| A-S1 記録 | アプリの骨組み(ホーム・記録 HUD・設定)。ホームの衛星表示と緑の READY(Android は衛星の数と信号の強さまで出せる)。記録サービス(試作の書き込みを整理)、常駐通知に MARK / STOP。events.bin(マーカー・衛星取得・電池・温度)。SYNC の音(AAudio で出力時刻を取る) | 実車で START → MARK / SYNC → STOP、iPhone と同じ形式のセッションが残る |
| A-S2 振り返り・書き出し | セッション一覧と詳細(地名は Android の Geocoder)、リプレイ(MapLibre + DriveKit のフレーム)、書き出し(DriveKit の JSON / GPX / CSV を共有メニューへ) | 書き出しが今の Vlog 制作の流れにそのまま入る |
| A-S3 堅牢性・品質 | 落ちたときの復旧(DriveKit で再集計)、記録中の G(DriveKit の MountCalibrator を JNI で)、品質画面 | 2 時間記録・強制終了からの復旧 |
| 後回し | Wear OS、Android Auto、Google Maps(#40)、APK の小型化(Foundation の国際化データを外す) | — |

置き場所: 試作ブランチ(#39)は main に入れない。A-S1 の最初に、試作から使う部分(`Android/` の記録と JNI、DriveKit の移植対応、`drivekit-cli`)を整理して main に入れ、
以後は iOS と同じく `feature/a-sN-…` のブランチで進める。

