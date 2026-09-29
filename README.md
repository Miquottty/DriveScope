# DriveScope

iPhone / iPad だけで車載 Vlog 向けのテレメトリ（位置・速度・高度・姿勢・加速度）を記録し、走行後にルートと HUD を時系列で再生・書き出しするアプリです。個人利用向け（App Store 非公開）。

- 計画・設計: [docs/PLAN.md](docs/PLAN.md)（完了条件の状況は §1）
- テストと実機チェックリスト: [docs/TESTING.md](docs/TESTING.md)
- デザインモック: [design/mock/](design/mock/README.md)（iPhone 10 枚 + iPad 6 枚）
- 開発メモ（コマンド・規約）: [CLAUDE.md](CLAUDE.md)

## 主な機能

- **記録**: GPS（1 Hz）+ Core Motion（プリセットで 0 / 10 / 25 / 50 / 100 Hz）+ 気圧高度を、追記型のバイナリファイルに保存します。2 秒ごとに書き込むため、強制終了しても直前まで残ります。
- **信頼性**: バックグラウンド記録、Watchdog（GPS 途絶通知と、停止時のデッドマン通知）、起動時の復旧 / 再開。
- **Live Activity**: ロック画面、Dynamic Island、StandBy、CarPlay / Apple Watch 用の小サイズ表示。MARK / STOP を実行でき、Watch のダブルタップで MARK できます。
- **振り返り**: 地図、統計、地名と自動タイトル、Timeline Replay（地図・HUD・速度グラフが同期）。
- **書き出し**: JSON（ロスレス）、CSV（Vlog 用 30 fps / 10 Hz、SYNC を t=0 とする）、GPX。
- **マウント補正**: 重力と発進加速から、端末の向きを車両の座標系に自動で合わせます。
- 日本語 / 英語をアプリ内で切り替えられます。iPad 専用のレイアウトがあります（分割表示、大型 HUD、キーボードショートカット）。

## ビルドとテスト

Xcode 27.2 beta（`/Applications/Xcode-beta.app`）を使います。`scripts/xc.sh` が `DEVELOPER_DIR` を固定するので、`xcode-select` を変更する必要はありません。

```bash
scripts/xc.sh test
```

```bash
scripts/xc.sh test-ui
```

```bash
scripts/xc.sh run -DriveSim akagi -DriveSimSpeed 10
```

- `test`: DriveKit の単体テスト（macOS）
- `test-ui`: UI テスト（iPhone 18 Pro シミュレータ）
- `run -DriveSim akagi`: 赤城山のスクリプト走行でシミュレータ起動（位置情報の許可は不要）

実機で使うときは Xcode でチーム `3X6HG4QJA8` の署名を選び、端末にインストールしてください。

## 構成

| パス | 内容 |
|---|---|
| `App/`, `Features/` | SwiftUI アプリ（iPhone / iPad） |
| `LiveActivity/`, `Shared/` | Live Activity（Widget Extension）と App Intents |
| `Packages/DriveKit/` | Domain / Sensors / Storage / Recording / Replay / Export |
| `.github/workflows/ci.yml` | CI（Xcode 27 ランナー: 単体テスト、実機向けビルド、UI テスト） |
