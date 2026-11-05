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
- **動画フォーマット**: HEVC（ルックを焼き込み）/ ProRes 422 HQ / ProRes RAW / ProRes RAW HQ、SDR / HDR(HLG) / Apple Log
  - RAW・Log・ProRes ではルックはプレビューのみに適用し、ファイルにはメタデータ（`com.luxcam.look`）として記録します。
  - 非対応端末では選択肢が無効化されます（ProRes RAW は iPhone 17 Pro 以降 / iOS 26 以降を想定）。

## ビルド
1. Xcode 16 以降（推奨 Xcode 26）で `LuxCam.xcodeproj` を開く
2. Signing & Capabilities で Team を設定（Bundle ID `com.example.LuxCam` は適宜変更）
3. 実機（iPhone, iOS 17 以降）で実行 ※ シミュレータではカメラは使えません

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
