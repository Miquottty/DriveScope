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
| 加速度・重力の単位と符号 | m/s²、反力の向き(上向きに置くと重力 z = +9.81) | ×(−1 / 9.80665) で g、Core Motion の符号に | 机上で z の符号を確認。向きの確認(3 姿勢)で x・y も確定する |
| センサーの時刻 | `SensorEvent.timestamp` は elapsedRealtime(スリープ中も進む)基準 | 全ストリームをこの時計にそろえ、manifest の `startUptime` も同じ時計 | 確定(届くまでの遅れ 1〜7 ms) |
| 周期 | 50 Hz を指定すると 59.3 Hz。重力・重力除去の加速度(合成センサー)は 100 Hz を指定しても 59 Hz 止まり | 生の加速度を 200 Hz で受け取り 20 ms の格子に間引き、最新の重力を引いて「重力を除いた加速度」を作る | 確定(下の記録結果) |
| 位置の時刻 | `Location.elapsedRealtimeNanos` | unix 時刻 = 開始時刻 + (fix の elapsedRealtime − 開始) | — |
| 高度 | 楕円体高。Android 14 以降は平均海面からの高さも取れる | 平均海面からの高さを優先(iOS と同じ基準) | — |
| 気圧 | hPa。1 Hz を指定しても約 36 Hz で届き、1 件ごとのばらつき 1.2 m | 1 秒ごとの平均を 1 件(CMAltimeter と同じ間隔)。÷10 で kPa、相対高度は最初の値からの差 | 確定(ばらつき 0.37 m) |
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

(未着手)

## 中核の共有(Swift on Android)

(未着手。NDK はユーザーが Android Studio で導入)
