# LuxCam

Leica風のミニマルなUIを持つ iPhone 用カメラアプリ（SwiftUI + AVFoundation）。

## 機能
- **モード切替**: CINEMATIC / VIDEO / PHOTO / PORTRAIT（純正カメラと同様のモードストリップ、左右スワイプ対応）
- **マニュアル操作**: フォーカス（レンズ位置）、シャッタースピード、ISO、露出補正（AUTO復帰可）
- **ルック（LUT）切替**: iOS純正 / LEICA / HASSELBLAD / SIGMA
  - LEICA: Classic / Contemporary / Monochrom
  - HASSELBLAD: Natural / Portrait
  - SIGMA: Teal & Orange / Warm Gold / Powder Blue / Mono
  - ※ いずれもメーカー純正LUTではなく、各社の色傾向を参考に手続き的に生成したオリジナルの近似ルックです。
- **動画フォーマット**: HEVC / ProRes 422 HQ / 422 / 422 LT / 422 Proxy / ProRes RAW / RAW HQ、SDR / HDR(HLG) / Apple Log、24〜120fps
  - ルックを焼き込むのは HEVC + SDR のみ。HDR・Log・ProRes・RAW ではルックはプレビューのみに適用し、ファイルにはメタデータ（`com.luxcam.look`）として記録します。
  - 端末が対応していない選択肢は自動で無効化されます。
- **写真フォーマット**: HEIF / Apple ProRAW（DNG を HEIF と同時保存、48MP 対応機種では最大解像度）

### iPhone 16 Pro での対応状況
| 規格 | 対応 | 備考 |
|---|---|---|
| ProRes 422 HQ / 422 / LT / Proxy | ○ | 4K60 以上の ProRes は外部 SSD が必要な場合あり |
| Apple Log | ○ | ProRes 422 HQ + LOG がおすすめ設定（フォーマット画面にボタンあり） |
| HDR (HLG) / 120fps | ○ | フォーマット依存 |
| Apple ProRAW（写真） | ○ | 48MP DNG |
| ProRes RAW（動画） | × | iPhone 17 Pro 以降のみ。選択肢は「非対応」と表示 |

## ビルド
1. Xcode 16 以降（推奨 Xcode 26）で `LuxCam.xcodeproj` を開く
2. Signing & Capabilities で Team を設定（Bundle ID `com.example.LuxCam` は適宜変更）
3. 実機（iPhone, iOS 17 以降）で実行 ※ シミュレータではカメラは使えません
4. プレビューが上下逆さまに表示される場合は `Preview/CameraPreviewView.swift` の `flipVertically` を `true` にしてください

## 構成
```
LuxCam/
  Core/     共有型（モード・ルック・マニュアル設定・状態）と契約 (CONTRACT.md)
  Capture/  AVFoundation セッション、写真/ポートレート処理、動画記録（AVAssetWriter / MovieFileOutput）
  Looks/    手続き的 3D LUT（CIColorCube）生成、Apple Log → 表示変換
  Preview/  Metal(MTKView) + Core Image によるルック適用済みライブプレビュー
  UI/       Leica風 SwiftUI 画面（モードストリップ、ダイヤル、ルックピッカー等）
  App/      エントリポイント
```
プロジェクトは Xcode 16 のフォルダ同期グループを使用しているため、`LuxCam/` 以下に追加した Swift ファイルは自動でビルド対象になります。
