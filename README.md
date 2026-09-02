# CE_Layer_iOS — Windows 95 fixed machine for iPhone / iPad

Windows 95 を「互換レイヤー」ではなく、x86 PC として iOS 上で動かす専用アプリです。汎用 VM 作成画面は持たず、Pentium-class / 64 MB RAM / S3 SVGA / Sound Blaster 16 / IDE という固定構成で、ユーザー所有のセットアップ済み Windows 95 HDD を直接起動します。

GitHub Actions は arm64/iPhoneOS 向けのソフトウェアインタープリタ版コアをビルドし、コード署名なしの `Win95iOS-unsigned.ipa` を Artifact に出力します。

## 実装済み

- DOSBox Pure の x86 interpreter を固定コミットからビルド（JIT/dynarec 無効）
- Pentium slow、64 MB、約 Pentium 100 MHz 相当、S3 Trio64、SB16 の固定オプション
- raw `.img` / `.vhd` の BIOS 自動起動（DOSBox Pure のスタートメニューを表示しない）
- 512-byte sector 単位の永続 differencing disk
- base HDD は変更せず、変更 sector のみ `win95-base-CDRIVE.sav` に保存
- Metal による XRGB8888 framebuffer 表示
- AVAudioEngine による 48 kHz stereo PCM 出力
- アスペクト比を維持する全画面 Metal 表示（iPhone、iPad、AirPlay ミラーリング対応）
- 画面内を移動できる折りたたみ式コンパクト操作メニュー
- タッチトラックパッド、長押しドラッグ、2本指右クリック／スクロール、左右クリック
- iOS ソフトウェアキーボード、USB/Bluetooth HID 物理キーボード、外部マウス／トラックパッド
- UTM 型の特殊キーバー（修飾キー、Esc、Tab、矢印、F1〜F12、編集・ロックキー）
- 複数 ISO/CUE/CHD の保存、一覧選択、ATAPI CD-ROM 交換/eject（大容量イメージのストリーミング取込）
- pause/resume、hardware reset、save/load state、Windows データ初期化
- Windows の正常な shutdown を検出したら DOSBox Pure のメニューを出さずアプリを終了
- background 移行時の state 保存と HDD overlay flush
- iPhone / iPad 共通 UI

## Windows 95 イメージについて

Windows 95 は Microsoft の著作物であり、このリポジトリには含まれません。自分が正当に所有する、セットアップ済みの raw HDD image を使用してください。

選択肢は2つです。

1. アプリ起動後に `.img` または `.vhd` を Files picker から選ぶ（推奨）。イメージは Application Support の固定名へコピーされます。
2. 自分専用の private fork / local checkout で `Win95iOS/BundledContent/win95-base.img` を置いてからビルドする。`.gitignore` 対象なので、誤って公開しないよう注意してください。

推奨 guest 設定:

- Windows 95 OSR2
- FAT16/FAT32 の raw IDE HDD（512-byte sector）
- Standard 101/102-Key keyboard
- S3 Trio64 display driver
- Sound Blaster 16: port `0x220`, IRQ `7`, DMA `1`, high DMA `5`
- 画面サイズ 640×480 または 800×600

イメージの簡易検査:

```bash
scripts/validate_disk.sh path/to/win95-base.img
```

## GitHub Actions

`Actions` → `Build unsigned IPA` → `Run workflow` を実行します。完了後、Artifact `Win95iOS-unsigned` から IPA を取得できます。

workflow は次を実行します。

1. DOSBox Pure の固定 commit `7f6e8fb7385fa446d1444d671063268520bf9b54` を取得
2. [iOS fixed-disk patch](patches/dosbox-pure-ios-fixed-disk.patch) を適用
3. `DISABLE_DYNAREC=1` の iOS arm64 static library を生成
4. `CODE_SIGNING_ALLOWED=NO` で `.app` をビルド
5. `Payload/Win95iOS.app` を unsigned IPA として zip 化

未署名 IPA は App Store へ直接インストールできません。AltStore、SideStore、TrollStore、Apple Developer certificate を使った再署名など、端末環境に合う方法が必要です。

## macOS でのローカルビルド

Xcode 16.4 が必要です。

```bash
scripts/fetch_core.sh
scripts/build_core.sh
xcodebuild \
  -project Win95iOS.xcodeproj \
  -scheme Win95iOS \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build
```

## ストレージ構造

```text
base image (read only)
        │
        ├── unchanged sector ─────────────┐
        │                                 ▼
        └── changed sector → FFDD overlay → virtual IDE HDD → Windows 95
```

iOS 側の主な保存先:

```text
Application Support/Win95/
├── win95-base.img / .vhd       # Files picker から取り込んだ場合のみ
├── suspend.state
├── CDs/
│   ├── install-disc-1.iso
│   └── install-disc-2.iso
├── Saves/
│   └── win95-base-CDRIVE.sav   # 変更 sector のみ
└── System/
```

通常の reset / power cycle では overlay を消しません。「Reset Windows Data」だけが overlay と save state を削除します。

## 操作

- 右上の `•••` をタップ: コンパクトメニューを展開／折りたたみ
- `•••` をドラッグ: メニューを画面内の任意位置へ移動
- 1本指ドラッグ: マウスカーソル移動
- タップ: 左クリック
- 指を動かさず長押ししてからドラッグ: 左ボタンを押したまま移動（ペイント、範囲選択、ウィンドウ移動）。通常の1本指移動中にドラッグへ切り替わることはありません。
- 2本指タップ: 右クリック
- 2本指ドラッグ: ホイールスクロール
- 外部マウス／トラックパッド: 移動、左右ボタン、ドラッグ、スクロールを直接送信

## 現在の制約

- DOSBox Pure が提供する NE2000 は guest から検出できますが、この専用 frontend はインターネット向け user-mode NAT をまだ接続していません。
- Win95 の CPU 負荷は高く、古い端末では実時間速度に届かない場合があります。iOS の実行コード制限に抵触しないよう JIT は意図的に使用していません。
- save state は core revision、CPU、RAM、video 設定に依存します。アプリ更新後に互換性がない場合は通常 boot を使用してください。
- Windows の shutdown 完了時は HDD overlay を flush してからアプリが自動終了します。

## ライセンス

frontend と結合成果物は DOSBox Pure に合わせて GPL-2.0-or-later として扱います。詳細は [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) を参照してください。DOSBox Pure のライセンス本文と著者情報は core build 時に app bundle へコピーされます。
