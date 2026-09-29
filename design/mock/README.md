# DriveScope Design Mock

デザインモックの原本です。編集は下記のキャンバス（Design canvas アーティファクト）で行い、変更したらこのフォルダに取り込み直してコミットします。

- **Canvas:** https://claude.ai/artifact/AFmN9QtGv2Yo15gxyZfBte
- **Snapshot:** 2026-09-29（canvas version `1790659186-ccd0`）

## ファイル

| ファイル | アートボード | サイズ (pt) |
|---|---|---|
| `canvas.json` | キャンバスのレイアウト（配置・タイトル・注記） | — |
| `Main.dc.html` | 1 · Home / Ready | 390×844 |
| `Recording.dc.html` | 2 · Recording HUD | 390×844 |
| `Sessions.dc.html` | 3 · Sessions | 390×844 |
| `Detail.dc.html` | 4 · Session Detail | 390×844 |
| `Replay.dc.html` | 5 · Timeline Replay | 390×844 |
| `LiveActivity.dc.html` | 6 · Lock Screen Live Activity | 390×200 |
| `Recovery.dc.html` | 7 · Crash Recovery Sheet | 390×200 |
| `RecordingLandscape.dc.html` | 8 · Recording HUD · Landscape | 844×390 |
| `StandBy.dc.html` | 9 · StandBy | 844×390 |
| `DynamicIsland.dc.html` | 10 · Dynamic Island / CarPlay small | 844×260 |

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

## 注意

- `.dc.html` はキャンバスのランタイム（`support.js`）上で描画する形式なので、単体でブラウザに開いても正しく表示されません。閲覧は上記キャンバスで行ってください。
- 表示している数値・地名（例: "Akagi Touge"）はすべてダミーです。
