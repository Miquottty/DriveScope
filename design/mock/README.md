# DriveScope Design Mock

デザインモックの原本です。編集は下記のキャンバス（Design canvas アーティファクト）で行い、変更したらこのフォルダに取り込み直してコミットします。

- **Canvas:** https://claude.ai/artifact/AFmN9QtGv2Yo15gxyZfBte
- **Snapshot:** 2026-09-29（canvas version `1790674627-c7f0`、iPad アートボード追加）

## ファイル

| ファイル | アートボード | サイズ (pt) |
|---|---|---|
| `canvas.json` | キャンバスのレイアウト（配置・タイトル・注記） | — |
| `Main.dc.html` | 1 · Home / Ready | 390×844 |
| `MainLandscape.dc.html` | 1b · Home / Ready · iPhone 横（Record ダッシュボード。Pro Max 横も iPad の分割表示にしない） | 844×390 |
| `MainLandscapeMax.dc.html` | 1c · Home / Ready · iPhone 横 · Pro Max | 956×440 |
| `Recording.dc.html` | 2 · Recording HUD（縦。速度・REC 経過時間・G をマウント越しに読める大きさに。2026-09-30 改訂。MARK / HIGHLIGHT / SYNC は 2026-10-01） | 390×844 |
| `RecordingPortraitV2Max.dc.html` | 2b · Recording HUD · Pro Max（余った高さは G メーターへ） | 440×956 |
| `RecordingPortraitV2Start.dc.html` | 2c · Recording HUD · 開始直後（測位前・GPS EST.） | 390×844 |
| `Sessions.dc.html` | 3 · Sessions | 390×844 |
| `Detail.dc.html` | 4 · Session Detail | 390×844 |
| `Replay.dc.html` | 5 · Timeline Replay（地図は伸縮、操作ボタンは下にオーディオプレイヤー風。2026-09-30 改訂） | 390×844 |
| `ReplayV2Max.dc.html` | 5b · Timeline Replay · Pro Max | 440×956 |
| `LiveActivity.dc.html` | 6 · Lock Screen Live Activity | 390×200 |
| `Recovery.dc.html` | 7 · Crash Recovery Sheet | 390×200 |
| `RecordingLandscape.dc.html` | 8 · Recording HUD · Landscape（ボタンは 4 等分。速度は MARK / HIGHLIGHT の上、G は SYNC / STOP の上。2026-10-01 改訂） | 844×390 |
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

## Recording HUD のボタン（2026-10-01 HIGHLIGHT 追加）

MARK（ブックマーク）· HIGHLIGHT（見どころ。Vlog で前方カメラに切り替える瞬間）· SYNC（カメラ同期）· STOP（長押し）の 4 つ。HIGHLIGHT は MARK と同じ確認表示（琥珀のチェック + 触覚）だけで、音やフラッシュは出さない。

| アートボード | 配置 |
|---|---|
| 2 / 2b / 2c（縦） | MARK · HIGHLIGHT · SYNC を 3 等分で 1 列（64 pt）。1 つ約 100〜125 pt の幅では「HIGHLIGHT」をアイコンの横に置けないので、3 つともアイコンを文字の上に積む。その下に 1 行の説明（11 pt、収まらなければ縮小）、STOP は従来どおり全幅 68 pt |
| 8 / 8b（横） | MARK · HIGHLIGHT · SYNC · STOP を 4 等分（56 pt）。上段も同じ 4 列に乗せ、速度は左 2 列、G は右 2 列 |
| 12（iPad 横） | 4 等分（92 pt）、アイコン・タイトル・キーキャップを横並び |
| 16（iPad 縦） | 4 等分（100 pt）。1 つ約 180 pt なので、アイコンとキーキャップをタイトルの上に積む |

- STOP は長押しでしか止まらないので、他のボタンと同じ幅にしても誤って止まることはない。iPad の旧比率 MARK 1 : SYNC 1 : STOP 1.6 のままでは、HIGHLIGHT とキーキャップが小さい iPad で収まらない。
- HIGHLIGHT の色は琥珀（`#F2A33A`）。Replay / Session Detail のピン・チップ・スパークラインの線は MARK 白、SYNC 緑、HIGHLIGHT 琥珀。
- この変更はローカルの `.dc.html` のみ。キャンバスへの反映は次回の取り込み時に行う。

## iPad の視認性ルール

- 1 画面 1 主役（運転中は速度・G、振り返りは地図）
- 本文 15 pt 以上、ラベル 13 pt（大文字）、主要数値 28 pt 以上（HUD の速度は 260〜280 pt）
- iPad では `#5C6670` を文字色に使わない（4.5:1 未満）。副次テキストは `#B4BEC8` / `#8A94A0`
- カード: 角丸 16、内側余白 20、間隔 16〜20、外側余白 32
- タップ領域 52 pt 以上（HUD のボタンは 92〜100 pt）。STOP は長押しのみ
- サイドバー = ナビゲーション + セッション一覧。幅の狭いマルチタスク時は iPhone のタブに切り替え
- キーボード: HUD は M / H / S、Replay は Space・← →・[ ]

## G メーターの向き

- 点は運転者が押される向きに動く（ボウルの中のボール。GT-R や GR ヤリスの G モニターと同じ）: 左旋回 → 右、右旋回 → 左、減速 → 上、加速 → 下。
- LATERAL / LONG の数値はエンジンの符号のまま（+ = 左 / 加速）。例: LATERAL +0.21・LONG −0.08 なら点は右上。
- 2026-10-01 に全アートボードの点と軌跡をこの向きに揃えた（それまでは iPhone が加速度ベクトル向き、iPad が左右だけ逆で混在）。

## 注意

- `.dc.html` はキャンバスのランタイム（`support.js`）上で描画する形式なので、単体でブラウザに開いても正しく表示されません。閲覧は上記キャンバスで行ってください。
- 表示している数値・地名（例: "Akagi Touge"）はすべてダミーです。

## Home の START（2026-10-06 READY 追加）

Home は表示中に START 前から衛星を探す（PLAN §9.3 / §11）。START の文字は常に「START」のままで、色と下の 1 行で状態を伝える。琥珀のときも押せる（屋根の下でカメラを準備しながらの START は普通の使い方）。

| 状態 | 円の色 | 下の 1 行 |
|---|---|---|
| 探索していない（未許可・おおよその位置・スクリプト走行） | 琥珀 `#F2A33A` | Record drive / ドライブを記録 |
| 衛星を探索中（Wi‑Fi の位置だけ、または衛星が 15 s 途絶） | 琥珀 `#F2A33A` | Searching satellites / 衛星を探索中 |
| 衛星取得（GPS セルが ±m の緑） | 緑 `#7BD88F` | READY · satellites locked / READY · 衛星 OK |

アートボード 1（`Main.dc.html`）は GPS ±3.2 m の READY 状態で描いている。

