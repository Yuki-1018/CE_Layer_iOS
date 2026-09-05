# CE_Layer_iOS — Windows 95 fixed machine for iPhone / iPad

Windows 95 を「互換レイヤー」ではなく、x86 PC として iOS 上で動かす専用アプリです。汎用 VM 作成画面は持たず、Pentium / 128 MB RAM / S3 SVGA / Sound Blaster 16 / IDE という固定構成で、ユーザー所有のセットアップ済み Windows 95 HDD を直接起動します。

GitHub Actions は arm64/iPhoneOS 向けのソフトウェアインタープリタ版コアをビルドし、コード署名なしの `Win95iOS-unsigned.ipa` を Artifact に出力します。

## 実装済み

- DOSBox Pure の x86 interpreter を固定コミットからビルド（JIT/dynarec 無効）
- Pentium (`pentium_slow`)、128 MB、77000 cycles、S3 Trio64、SB16 の固定オプション（このコアではMMX無効のため `pentium_mmx` は使用しません）
- raw `.img` / `.vhd` の BIOS 自動起動（DOSBox Pure のスタートメニューを表示しない）
- 初回起動時やベースイメージ未配置時に表示する、iPhone横向きにも対応したイメージ選択画面
- 512-byte sector 単位の永続 differencing disk
- base HDD は変更せず、変更 sector のみ `win95-base-CDRIVE.sav` に保存
- Metal による XRGB8888 framebuffer 表示
- AVAudioEngine による 48 kHz stereo PCM 出力
- NE2000からlibslirpへ接続するDHCP/DNS付きuser-mode NAT
- アスペクト比を維持する全画面 Metal 表示（iPhone、iPad、AirPlay ミラーリング対応）
- 画面内を移動できる折りたたみ式コンパクト操作メニュー
- タッチトラックパッド、長押しドラッグ、2本指右クリック／スクロール
- iOS ソフトウェアキーボード、GameController HID 経由のUSB/Bluetooth物理キーボード、外部マウス／トラックパッド
- UTM 型の特殊キーバー（Win/Ctrl/Alt/Shiftと文字・特殊キーの同時押し、Esc、Tab、矢印、F1〜F12、編集・ロックキー）
- 複数 ISO/CUE/CHD の保存、専用一覧からの追加・mount・eject・削除（ストリーミング取込、DOSのドライブ登録を経由しないATAPIメディア交換、起動・リセット時の再接続）
- 別アイコンで判別できる pause/resume、一時停止状態の自動保存・次回復帰、hardware reset
- Windows の正常な shutdown を検出したら DOSBox Pure のメニューを出さずアプリを終了
- background 移行時と正常終了時の HDD overlay flush
- iPhone / iPad 共通 UI

## Windows 95 イメージについて

Windows 95 は Microsoft の著作物であり、このリポジトリには含まれません。自分が正当に所有する、セットアップ済みの raw HDD image を使用してください。

選択肢は2つです。

1. 初回起動時に表示されるセットアップ画面から `.img` または `.vhd` を Files picker で選ぶ（推奨）。イメージは「このiPhone/iPad内」→アプリ名→`Win95` へコピーされます。後からベースイメージを削除した場合も、次回起動時に同じ画面へ戻ります。
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

IPAビルドの前にLinux上で合成IMG/VHD/ISOを使った回帰テストを実行します。netpacket callbackの登録・開始・停止、FAT16からの起動、差分の永続化、CHSの末尾を超えるLBA、不正セクタと途中書き込みからの復旧、512MB ISOの連続交換・読み出し・メモリ使用量、交換失敗時のメディア保持、リセットと一時停止復元後のCD読み出しを確認します。Windows本体を使用する実機テストは別途必要です。

続いてIPAをビルドします。

1. DOSBox Pure の固定 commit `7f6e8fb7385fa446d1444d671063268520bf9b54` を取得
2. [iOS fixed-disk patch](patches/dosbox-pure-ios-fixed-disk.patch) を適用
3. `DISABLE_DYNAREC=1` の iOS arm64 static library を生成
4. SHA-256を固定したUTM 4.7.5配布物からiOS用libslirp/GLib frameworkを取得
5. `CODE_SIGNING_ALLOWED=NO` で `.app` をビルド
6. `Payload/Win95iOS.app` を unsigned IPA として zip 化

未署名 IPA は App Store へ直接インストールできません。AltStore、SideStore、TrollStore、Apple Developer certificate を使った再署名など、端末環境に合う方法が必要です。

## macOS でのローカルビルド

Xcode 16.4 が必要です。

```bash
scripts/fetch_core.sh
scripts/build_core.sh
scripts/fetch_network_runtime.sh
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

可変長VHDでも差分は仮想ディスクの論理セクタに対して記録します。`.sav` 内の範囲外セクタはファイルを保持したまま読み飛ばし、有効なセクタを読み戻します。書きかけの末尾を検出した場合は、原本を同じフォルダの `.sav.recovery-XXXXXX` にバックアップしてから不完全な末尾だけを修復します。ヘッダー自体が壊れている保存データでは、削除せずエラーを表示します。これらは保存コンテナの復旧であり、Windows内ですでに壊れたファイルシステムの完全修復を保証するものではありません。

CD読み込み時はISOの形式判定を先に行い、CUEとしての試し読みは1MBまでに制限します。ISO全体をCUEテキストとしてメモリへ取り込むことはありません。iOSの絶対パスからの読み込みはホストのファイルだけを参照し、Windows実行中のDOS用SDA/DTAやドライブ表にはアクセスしません。

旧CDバックエンドからの更新時は `automatic-suspend.state` を `automatic-suspend.previous-core-UUID.state` へ退避し、一度通常起動します。必要なCDが見つからないときも、そのCDを前提とする一時停止状態は `.media-unavailable-UUID.state` へ退避します。HDDの `.sav` は削除しません。更新後に作成した一時停止状態は引き続き復元できます。

ローカルで同じ回帰テストを実行する場合:

```bash
scripts/fetch_core.sh
bash scripts/test_core_storage.sh
```

## 操作

- 右上の `≡` をタップ: コンパクトメニューを展開／折りたたみ
- `≡` をドラッグ: メニューを画面内の任意位置へ移動
- キーボードアイコン: ソフトウェアキーボードを表示／非表示
- `DOS`: `Alt+Enter` を送信してDOSプロンプトの全画面表示を切り替え。日本語版Windows 95 OSR2.1でウィンドウ表示が黒くなる場合の回避にも使用します。
- 特殊キーバーの Win/Ctrl/Alt/Shift: 選択後に文字または特殊キーを押すと同時押しとして送信
- `CD`: CD-ROM 管理画面を開く。保存済みイメージのタップでライブmount、`CDを取り出す` で eject、左スワイプで削除。Windowsやアプリを終了せずにATAPIメディアを交換します。
- 保存したCD選択を次回起動時に再接続します。新しいATAPIバックエンドでのマウント中に異常終了した場合は一度だけCDなしで起動し、選択情報を保持して復旧を案内します。
- `⏸` / `▶`: Windows の一時停止／再開（現在実行できる操作のアイコンを表示）。一時停止中にアプリを閉じた場合は、次回起動時に保存地点を復元して一時停止画面へ戻ります。
- 1本指ドラッグ: マウスカーソル移動
- タップ: 左クリック
- 指を動かさず長押ししてからドラッグ: 左ボタンを押したまま移動（ペイント、範囲選択、ウィンドウ移動）。通常の1本指移動中にドラッグへ切り替わることはありません。
- 2本指タップ: 右クリック
- 2本指ドラッグ: ホイールスクロール
- 外部マウス／トラックパッド: 移動、左右ボタン、ドラッグ、スクロールを直接送信

## 現在の制約

- NE2000はuser-mode NAT（libslirp）へ接続され、外向きTCP/UDPとDNSを利用できます。Windows 95ではNE2000互換ドライバをI/O `0x300`、IRQ `10`で設定し、TCP/IPを追加してIPアドレスを自動取得してください。割り当ては通常 `10.0.2.15/24`、ゲートウェイ `10.0.2.2`、DNS `10.0.2.3`です。NATのため外部からguestへの新規接続は受け付けません。また当時のブラウザは現在のHTTPS/TLSに対応しない場合があります。
- 日本語・韓国語版Windows 95 OSR2系には、DOSBox PureのNormal CPU coreでウィンドウ版MS-DOSプロンプトの再描画が壊れる既知の互換性問題があります。`DOS`ボタンまたはショートカットの［プロパティ］→［画面］→［全画面表示］を使用してください。
- Win95 の CPU 負荷は高く、古い端末では実時間速度に届かない場合があります。iOS の実行コード制限に抵触しないよう JIT は意図的に使用していません。
- Windows の shutdown 完了時は HDD overlay を flush してからアプリが自動終了します。

## ライセンス

frontend と結合成果物は DOSBox Pure に合わせて GPL-2.0-or-later として扱います。詳細は [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) を参照してください。DOSBox Pure のライセンス本文と著者情報は core build 時に app bundle へコピーされます。
