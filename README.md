# LuxCam

Leica風のミニマルなUIを持つ、iPhone用のカメラアプリです（SwiftUI + AVFoundation + Metal / Core Image）。

## 機能

### 撮影モード・マニュアル操作
- **モード切替**：CINEMATIC / VIDEO / PHOTO / PORTRAIT
  - 純正カメラと同じようにモードストリップで切り替える
  - スワイプでも切り替えられる（縦持ちは左右、横持ちは上下）
- **マニュアル操作**：フォーカス（レンズ位置）、シャッタースピード、ISO、露出補正
  - ダイヤルで操作し、AUTOに戻せる
  - 現在のISO・シャッタースピード・フォーカス位置をプレビューの下に表示する
- **ピント合わせ**：プレビューをタップした位置にピントと露出を合わせる
- **グリッドと枠線**：三分割グリッドをオン・オフできる。PHOTOモードでは写る範囲の四隅に枠線を表示する

### ルック（色）
| ブランド | ルック |
|---|---|
| iOS | STANDARD（純正のまま） |
| LEICA | Classic / Contemporary / Monochrom |
| HASSELBLAD | Natural / Portrait |
| SIGMA | Teal & Orange / Warm Gold / Powder Blue / Mono |

- ライブプレビューにも適用される（MTKView + CIColorCube）
- 各社純正のLUTではなく、色の傾向を参考にプログラムで生成したオリジナルの近似

### カメラ本体・レンズの選択（GEAR）
| ブランド | 本体 | レンズ |
|---|---|---|
| LEICA | M11 / M11 Monochrom / M10 / M9 / M8 / SL3 / SL3-S | Summicron-M 28 f/2、Summilux-M 35 f/1.4、Noctilux-M 50 f/0.95、APO-Summicron-M 90 f/2、APO-Summicron-SL 35/50 f/2（SL系の本体はMレンズも使える） |
| HASSELBLAD | X2D 100C / 907X CFV 100C | XCD 25V / 38V / 55V / 90V（f/2.5） |
| iPhone | 純正 | 13 / 24 / 48 / 120mm |

選んだ本体・レンズは、次のように反映されます。
- **画角**：換算焦点距離（レンズの焦点距離 × 本体の換算係数。M8は1.33、Hasselbladは0.79）に合わせて、超広角・広角・望遠カメラとズーム倍率を選ぶ
- **縦横比**：写真はLeicaが3:2、Hasselbladが4:3。プレビューも同じ比率で表示する（ProRAWのDNGは4:3のまま）
- **本体ごとの色の傾向**：
  - M9：CCDらしい濃い色乗り
  - M8：シャドウがマゼンタ寄りで、粒状感がある
  - M11 Monochrom：モノクロのルックだけを選べる
- **レンズの描写**：周辺減光、にじみ、シャープネス、開放でのソフトさ。レンズの開放F値が、PORTRAIT/CINEMATICの絞りダイヤルの下限になる
- 録画中は本体・レンズを変更できない

本体・レンズはチップ列の先頭の「GEAR」か、上部バーの「M9 · SUMMILUX 35」のような表示をタップして選びます。

### 写真
- **形式**：HEIF（最大約24MP）/ Apple ProRAW（DNGをHEIFと同時保存、最大48MP）
- **PORTRAIT**：深度データを使って背景をぼかす。ぼかしの強さは絞り値で調整する
- **シャッター**：iOS 17の低遅延撮影（ゼロシャッターラグ、レスポンシブキャプチャ）を使う
  - センサーが撮り終えたら、すぐ次を撮れる。ルックの適用と保存はバックグラウンドで続く（保存待ちが3枚になったら待つ）
  - 振動とフラッシュは、実際に撮影された瞬間に出る
  - 撮影直後に、小さなプレビュー画像からサムネイルを表示する

### 動画
- **コーデック**：HEVC / ProRes 422 HQ・422・LT・Proxy / ProRes RAW・RAW HQ
- **カラー**：SDR / HDR(HLG) / Apple Log
- **解像度・フレームレート**：4K / HD、24〜120fps
- **ルックの焼き込み**：HEVC + SDR + 30fps以下のときだけ。それ以外のときは、ルックはプレビューにだけ適用し、ファイルにはメタデータ（`com.luxcam.look` / `com.luxcam.gear`）として記録する
- 端末が対応していない選択肢は自動で無効になる
- FORMAT画面に「おすすめ（iPhone 16 Pro）：ProRes 422 HQ + LOG」のボタンがある

### 横向きUI
- 横に持つと、左にプレビュー、右に操作部を縦一列に並べたレイアウトになる
- 回転してもプレビューは途切れず、開いている設定もリセットされない
- 写真・動画は、持っている向きで保存される（`AVCaptureDevice.RotationCoordinator`）

### 撮影した写真・動画のビューア
- 左下のサムネイルをタップすると開く
- 左右スワイプで移動、ピンチやダブルタップで拡大、動画は再生できる
- **共有**：元のファイルのまま共有する（写真はHEIC、ProRAWはDNGも、動画は .mov）
- **削除**と**写真アプリで開く**のボタンがある
- LuxCamで撮った写真・動画を記録しているので、アプリを再起動しても見られる
- 最初に開いたときに、写真ライブラリの読み取り許可を求められる（制限付きアクセスでも、LuxCamで撮ったものは表示される）

## iPhone 16 Proでの対応状況
| 規格 | 対応 | 備考 |
|---|---|---|
| ProRes 422 HQ / 422 / LT / Proxy | ○ | 4K60以上のProResは外部SSDが必要な場合がある |
| Apple Log | ○ | ProRes 422 HQ + LOG がおすすめ |
| HDR (HLG) / 120fps | ○ | フォーマットによる |
| Apple ProRAW（写真） | ○ | 48MP DNG |
| ProRes RAW（動画） | × | iPhone 17 Pro以降のみ。選択肢は「非対応」と表示される |

## ビルドと実機での実行
必要なもの：Mac、Xcode 16以降（iOS 26の端末で動かすならXcode 26）、Apple ID（無料でも可）、iPhone（iOS 17以降）

1. `LuxCam.xcodeproj` をXcodeで開く
2. **TARGETS → LuxCam → Signing & Capabilities** を開き、次のように設定する
   - Automatically manage signing にチェックを入れる
   - Team に自分のアカウントを選ぶ
   - Bundle Identifier を `com.example.LuxCam` から一意な値に変える（例：`com.yourname.LuxCam`）
3. iPhoneをMacにつなぎ、iPhone側でデベロッパモードをオンにする（設定 → プライバシーとセキュリティ → デベロッパモード）
4. Xcodeの実行先にiPhoneを選び、⌘Rで実行する
5. 無料アカウントの場合は、iPhoneの「設定 → 一般 → VPNとデバイス管理」で開発元を信頼してから起動する
6. カメラ・マイク・写真ライブラリへのアクセスを許可する

補足：
- シミュレータではカメラが使えないため、実機が必要です。
- 無料アカウントでインストールしたアプリは、7日で起動できなくなります。Xcodeからもう一度実行すれば使えます。
- プレビューが上下逆さまに表示される場合は、`LuxCam/Preview/CameraPreviewView.swift` の `flipVertically` を `true` にしてください。

## 構成
```
LuxCam/
  Core/     共有の型（モード、ルック、本体・レンズ、状態）と、モジュール間の取り決め（CONTRACT.md）
  Capture/  AVFoundationのセッション、カメラとズームの選択、回転、写真・ポートレート処理、
            動画記録（AVAssetWriter / MovieFileOutput）、シネマティック、フォトライブラリへの保存
  Looks/    LUT（CIColorCube）の生成、Apple Logの表示変換、本体・レンズの描写
  Preview/  Metal（MTKView）+ Core Imageのライブプレビュー、フォーカス枠、グリッド・枠線
  UI/       SwiftUIの画面（縦・横のレイアウト、ダイヤル、GEAR選択、動画フォーマット、ビューア）
  App/      エントリポイント
```
Xcode 16のフォルダ同期方式のプロジェクトなので、`LuxCam/` 以下に追加したSwiftファイルは自動でビルド対象になります。

## 既知の制限
- 90mm前後のレンズは、望遠カメラ（120mm）だと狭すぎるため、広角カメラを拡大して画角を合わせる。そのぶん実質の解像度が下がる（約3.4MP相当）
- CINEMATICではレンズの画角は反映されず、24mmのまま。iOS 26のCinematic APIは、存在を確認してから呼ぶ作りで、使えない場合は通常の24fps HEVC録画になる
- 4K録画でルックを焼き込むときは、コマ落ちを防ぐためにシャープネス処理とシャドウの色かぶり処理を省いている（プレビューと少し見え方が違う）
- ビューアに出るのは、ビューアを追加した後に撮影したものだけ

## 免責
ルックと本体・レンズの描写は、各社の描写傾向を参考にしたオリジナルのエミュレーションです。各メーカーとは関係がなく、公認を受けたものではありません。製品名は各社の商標です。
