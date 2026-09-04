# CE_Layer_iOS — Windows 95 fixed machine for iPhone / iPad

Windows 95 を「互換レイヤー」ではなく、x86 PC として iOS 上で動かす専用アプリです。汎用 VM 作成画面は持たず、Pentium MMX / 128 MB RAM / S3 SVGA / Sound Blaster 16 / IDE という固定構成で、ユーザー所有のセットアップ済み Windows 95 HDD を直接起動します。

GitHub Actions は arm64/iPhoneOS 向けのソフトウェアインタープリタ版コアをビルドし、コード署名なしの `Win95iOS-unsigned.ipa` を Artifact に出力します。

## 実装済み

- DOSBox Pure の x86 interpreter を固定コミットからビルド（JIT/dynarec 無効）
- Pentium MMX 命令セット、128 MB、実機で60 fpsを維持しやすい77000 cycles、S3 Trio64、SB16 の固定オプション
- raw `.img` / `.vhd` の BIOS 自動起動（DOSBox Pure のスタートメニューを表示しない）
- 512-byte sector 単位の永続 differencing disk
- base HDD は変更せず、変更 sector のみ `win95-base-CDRIVE.sav` に保存
- Metal による XRGB8888 framebuffer 表示
- AVAudioEngine による 48 kHz stereo PCM 出力
- アスペクト比を維持する全画面 Metal 表示（iPhone、iPad、AirPlay ミラーリング対応）
- 画面内を移動できる折りたたみ式コンパクト操作メニュー
- タッチトラックパッド、長押しドラッグ、2本指右クリック／スクロール
- iOS ソフトウェアキーボード、GameController HID 経由のUSB/Bluetooth物理キーボード、外部マウス／トラックパッド
- UTM 型の特殊キーバー（Win/Ctrl/Alt/Shiftと文字・特殊キーの同時押し、Esc、Tab、矢印、F1〜F12、編集・ロックキー）
- 複数 ISO/CUE/CHD の保存、専用一覧からの追加・mount・eject・削除（大容量イメージのストリーミング取込、安全な起動時mount）
- 別アイコンで判別できる pause/resume、一時停止状態の自動保存・次回復帰、hardware reset
- Windows の正常な shutdown を検出したら DOSBox Pure のメニューを出さずアプリを終了
- background 移行時と正常終了時の HDD overlay flush
- iPhone / iPad 共通 UI

## Windows 95 イメージについて

Windows 95 は Microsoft の著作物であり、このリポジトリには含まれません。自分が正当に所有する、セットアップ済みの raw HDD image を使用してください。

選択肢は2つです。

1. アプリ起動後に `.img` または `.vhd` を Files picker から選ぶ（推奨）。イメージは「このiPhone/iPad内」→アプリ名→`Win95` へコピーされます。
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

`Actions` → `Build unsigned IPA` → `Run workflow` を実行します。実行画面ではホーム画面に表示するアプリ名、bundle ID、任意のカスタムアイコンURLを指定できます。アイコンは HTTPS で取得可能な1024×1024以上のPNG/JPEGを指定してください。空欄ならアイコンを追加せずにビルドします。完了後、Artifact `Win95iOS-unsigned` から IPA を取得できます。

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
Files > このiPhone/iPad内 > アプリ名 > Win95/
├── win95-base.img / .vhd       # Files picker から取り込んだ場合のみ
├── CDs/
│   ├── install-disc-1.iso
│   └── install-disc-2.iso
├── Saves/
│   ├── win95-base-CDRIVE.sav   # 変更 sector のみ
│   └── automatic-suspend.state # 一時停止中だけ保持する自動復帰状態
└── System/
```

このフォルダはファイルアプリから参照・編集できます。旧バージョンの `Application Support/Win95` は初回起動時にこの場所へ移動します。アプリ実行中にファイルを置換すると破損する可能性があるため、ベースイメージや保存データを編集するときはアプリを終了してください。

通常の reset / power cycle でも overlay は維持されます。Windowsの書き込みはbackground移行時と正常終了時にも明示的にflushされます。

## 操作

- 右上の `≡` をタップ: コンパクトメニューを展開／折りたたみ
- `≡` をドラッグ: メニューを画面内の任意位置へ移動
- キーボードアイコン: ソフトウェアキーボードを表示／非表示
- 特殊キーバーの Win/Ctrl/Alt/Shift: 選択後に文字または特殊キーを押すと同時押しとして送信
- `CD`: CD-ROM 管理画面を開く。保存済みイメージのタップでライブmount、`CDを取り出す` で eject、左スワイプで削除。Windowsやアプリを終了せずにATAPIメディアを交換します。
- 旧ビルドで保存されたCD選択や、マウント中に異常終了した状態を検出した場合は、起動ループを防ぐため一度だけCDなしで安全起動します。
- `⏸` / `▶`: Windows の一時停止／再開（現在実行できる操作のアイコンを表示）。一時停止中にアプリを閉じた場合は、次回起動時に保存地点を復元して一時停止画面へ戻ります。
- 1本指ドラッグ: マウスカーソル移動
- タップ: 左クリック
- 指を動かさず長押ししてからドラッグ: 左ボタンを押したまま移動（ペイント、範囲選択、ウィンドウ移動）。通常の1本指移動中にドラッグへ切り替わることはありません。
- 2本指タップ: 右クリック
- 2本指ドラッグ: ホイールスクロール
- 外部マウス／トラックパッド: 移動、左右ボタン、ドラッグ、スクロールを直接送信

## 現在の制約

- DOSBox Pure が提供する NE2000 は guest から検出できますが、この専用 frontend はインターネット向け user-mode NAT をまだ接続していません。
- Win95 の CPU 負荷は高く、古い端末では実時間速度に届かない場合があります。iOS の実行コード制限に抵触しないよう JIT は意図的に使用していません。
- Windows の shutdown 完了時は HDD overlay を flush してからアプリが自動終了します。

## ライセンス

frontend と結合成果物は DOSBox Pure に合わせて GPL-2.0-or-later として扱います。詳細は [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) を参照してください。DOSBox Pure のライセンス本文と著者情報は core build 時に app bundle へコピーされます。
