# Android 版の開発メモ

自分用の Android 版(Pixel 7 / Android 16)。計画は `docs/ANDROID_PLAN.md`、試作の結果と決定の根拠は `docs/ANDROID_SPIKE.md`。

## 構成

| 場所 | 中身 |
|---|---|
| `Android/` | Gradle プロジェクト(AGP 9.3.2、Kotlin 2.2、Compose、MapLibre)。アプリ ID `com.miquottty.drivescope`、minSdk 34 |
| `Android/swift/DriveKitBridge` | DriveKit(Swift)を Android 用の共有ライブラリにし、JNI の入口を置く Swift パッケージ |
| `Android/swift/build-bridge.sh` | 上をビルドして `Android/app/src/main/jniLibs/arm64-v8a/` へ(生成物は Git の管理外) |
| `Packages/DriveKit/Sources/drivekit-cli` | Mac 側の確認ツール。端末から取り出したセッションのフォルダを集計・書き出し |

役割分担: センサー・画面・通知・地名・音は Kotlin、記録エンジン・計算・補間・書き出しは DriveKit(Swift)。
記録データは iOS と同じ形式(`manifest.json` + `.bin`)。

## 必要なもの(この Mac では導入済み)

- Android Studio(付属の Java を `JAVA_HOME` に使う)と Android SDK 37、NDK r30(30.0.16248370、SDK Manager の NDK (Side by side))
- swiftly の Swift 6.4.0 と、同じ版の Swift SDK for Android(`swift sdk install …_android.artifactbundle.tar.gz`、
  NDK とのリンクは SDK に入っている `scripts/setup-android-sdk.sh`)。swiftly はシェルの設定を書き換えずに入れてあるので、
  ふだんの `swift` は Xcode のまま(iOS のビルドは今までどおり `scripts/xc.sh`)

## ビルドと実機

```bash
Android/swift/build-bridge.sh
cd Android && JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew assembleDebug
~/Library/Android/sdk/platform-tools/adb install -r Android/app/build/outputs/apk/debug/app-debug.apk
```

記録したセッションを Mac で確認する:

```bash
~/Library/Android/sdk/platform-tools/adb pull /sdcard/Android/data/com.miquottty.drivescope/files/Sessions <dir>
scripts/xc.sh swift run --package-path Packages/DriveKit drivekit-cli quality <dir>/<UUID>
scripts/xc.sh swift run --package-path Packages/DriveKit drivekit-cli export json <dir>/<UUID> --out <dir>
```

## Android で踏んだこと

- Swift の Foundation は一時フォルダ(TMPDIR)を使う。Android では未設定なので、最初にアプリのキャッシュを設定する(`DriveKitBridge.configure`)。
- 共有ストレージ(`/sdcard/Android/data/…`)からの `FileManager.copyItem` は権限のコピーで拒否される。ファイルの中身だけをコピーする。
- 50 Hz を指定しても 59.3 Hz で届く。重力・重力除去の加速度は 59 Hz 止まり → 生の加速度 200 Hz から 20 ms の格子を作る。
- 気圧は 1 Hz を指定しても約 36 Hz → 1 秒ごとの平均。
- 画面 OFF で CPU が眠るとセンサーが止まるので、記録中は PARTIAL_WAKE_LOCK。
- 端末を回すと Activity が作り直される(`configChanges` を指定済み)。
- 国土地理院のスタイルは PMTiles を GL JS の書き方で指定しているので、MapLibre Native 向けに `url` に書き換えて読む。
