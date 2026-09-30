# DriveScope Design Mock

デザインモックの原本です。編集は下記のキャンバス（Design canvas アーティファクト）で行い、変更したらこのフォルダに取り込み直してコミットします。

- **Canvas:** https://claude.ai/artifact/AFmN9QtGv2Yo15gxyZfBte
- **Snapshot:** 2026-09-29（canvas version `1790674627-c7f0`、iPad アートボード追加）

## ファイル

| ファイル | アートボード | サイズ (pt) |
|---|---|---|
| `canvas.json` | キャンバスのレイアウト（配置・タイトル・注記） | — |
| `Main.dc.html` | 1 · Home / Ready | 390×844 |
| `Recording.dc.html` | 2 · Recording HUD（縦。速度・REC 経過時間・G をマウント越しに読める大きさに。2026-09-30 改訂） | 390×844 |
| `RecordingPortraitV2Max.dc.html` | 2b · Recording HUD · Pro Max（余った高さは G メーターへ） | 440×956 |
| `RecordingPortraitV2Start.dc.html` | 2c · Recording HUD · 開始直後（測位前・GPS EST.） | 390×844 |
| `Sessions.dc.html` | 3 · Sessions | 390×844 |
| `Detail.dc.html` | 4 · Session Detail | 390×844 |
| `Replay.dc.html` | 5 · Timeline Replay | 390×844 |
| `LiveActivity.dc.html` | 6 · Lock Screen Live Activity | 390×200 |
| `Recovery.dc.html` | 7 · Crash Recovery Sheet | 390×200 |
| `RecordingLandscape.dc.html` | 8 · Recording HUD · Landscape（速度は MARK / SYNC の上、G は STOP の上。2026-09-30 改訂） | 844×390 |
| `RecordingLandscapeV2Max.dc.html` | 8b · Recording HUD · Landscape · Pro Max | 956×440 |
| `StandBy.dc.html` | 9 · StandBy | 844×390 |
| `DynamicIsland.dc.html` | 10 · Dynamic Island / CarPlay small | 844×260 |
| `iPadHome.dc.html` | 11 · iPad · Record ダッシュボード（サイドバー + START + センサー） | 1210×834 |
| `iPadRecording.dc.html` | 12 · iPad · Recording HUD · 横 | 1210×834 |
| `iPadDetail.dc.html` | 13 · iPad · Session Detail（地図主体） | 1210×834 |
| `iPadReplay.dc.html` | 14 · iPad · Timeline Replay（全画面） | 1210×834 |
| `iPadQuality.dc.html` | 15 · iPad · Quality | 1210×834 |
| `iPadRecordingPortrait.dc.html` | 16 · iPad · Recording HUD · 縦 | 834×1210 |

## デザイントークン（実装時の基準）

| 用途 | 値 |
|---|---|
| 背景（通常） | `#0B0D10` |
| 背景（Recording / StandBy） | `#000000` |
| サーフェス | `#14181D` |
| 区切り線 | `#1F252C` / `#2A323B` |
| 文字（主） | `#E8ECF0` |
| 文字（副） | `#8A94A0` / `#B4BEC8` |
| 文字（補助） | `#5C6670` |
| アクセント（琥珀） | `#F2A33A` |
| REC / STOP（赤） | `#E5484D` |
| GPS 良好（緑） | `#7BD88F` |
| 数値フォント | モックは IBM Plex Mono、アプリは SF Mono（`.monospacedDigit()`） |
| 本文フォント | モックは IBM Plex Sans、アプリはシステムフォント（日本語はヒラギノ） |

## iPad の視認性ルール

- 1 画面 1 主役（運転中は速度・G、振り返りは地図）
- 本文 15 pt 以上、ラベル 13 pt（大文字）、主要数値 28 pt 以上（HUD の速度は 260〜280 pt）
- iPad では `#5C6670` を文字色に使わない（4.5:1 未満）。副次テキストは `#B4BEC8` / `#8A94A0`
- カード: 角丸 16、内側余白 20、間隔 16〜20、外側余白 32
- タップ領域 52 pt 以上（HUD のボタンは 92〜100 pt）。STOP は長押しのみ
- サイドバー = ナビゲーション + セッション一覧。幅の狭いマルチタスク時は iPhone のタブに切り替え
- キーボード: HUD は M / S、Replay は Space・← →・[ ]

## 注意

- `.dc.html` はキャンバスのランタイム（`support.js`）上で描画する形式なので、単体でブラウザに開いても正しく表示されません。閲覧は上記キャンバスで行ってください。
- 表示している数値・地名（例: "Akagi Touge"）はすべてダミーです。
