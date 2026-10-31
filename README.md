# Hot Layout

外付けキーボードの接続・切断に合わせて、GNOME（Wayland）のキーボード配列を US / JIS に自動で切り替えます。

## Requirements

- OS：Ubuntu（26.04 で動作確認）
- デスクトップ：GNOME（Wayland セッション）
- 日本語入力：IBus + Mozc（`ibus-mozc`）
- GNOME 拡張：Input source D-Bus interface

## Installation

### Install

1. **GNOME 拡張を入れる**

   [extensions.gnome.org](https://extensions.gnome.org/extension/6547/input-source-d-bus-interface/) からインストールしてください。この拡張は、切り替えた配列を GNOME に反映させるために使います。

2. **インストーラを実行する**

   ```bash
   git clone https://github.com/<your-account>/hotplug-layout.git
   cd hotplug-layout
   ./install.sh
   ```

   画面の指示に従って、外付けキーボードを登録してください。インストール時に Mozc の設定ファイルをバックアップし、アンインストール時に元に戻します。

### Verify

```bash
journalctl --user -u hotplug-layout -f
```

キーボードを接続・切断すると、次のようなログが出ます。

```
[hotplug-layout] xkb  -> us  ([('xkb', 'us'), ('ibus', 'mozc-jp')])
[hotplug-layout] mozc -> us  (ibus restarted)
[hotplug-layout] reactivated: mozc-jp
```

### Uninstall

```bash
./uninstall.sh
```

`install.sh` で行った変更をすべて取り消し、インストール前の状態に戻します。ただし、GNOME 拡張は手順1で手動で入れたものなので残ります。

## Features

- **接続・切断で自動切り替え**：USB でも Bluetooth でも、接続するとそのキーボードの配列に、切断すると内蔵キーボードの配列に戻ります。
- **複数のキーボードに対応**：US の外付け、JIS の外付けなど、複数のキーボードをそれぞれの配列で登録できます。同時に接続しているときは、最後に接続したキーボードの配列になります。
- **キー入力を読まない**：見ているのはキーボードの接続・切断だけで、打った内容には一切触れません。キー入力を読むツールと違い、`input` グループへの追加（そのユーザーで動くどのプログラムからも全キー入力を読めるようになる設定）が不要です。普段は待機しているだけなので、動作も軽量です。

## How it works

- キーボードの接続・切断を udev で監視します。
- 接続中のキーボードに応じて、GNOME の配列を書き換えます。
- Mozc の配列も書き換えます。Mozc は自分の設定に配列を持っていて、日本語入力中は GNOME の配列ではなくそちらが使われるためです。
- IBus を再起動して、書き換えた Mozc の設定を読み込ませます。
- 設定を書き換えただけでは、いま使っている入力ソースには効きません。GNOME 拡張で入力ソースをいったん切り替えて戻し、新しい配列を適用します。

## Limitations

- 外付けキーボードを接続している間は、内蔵キーボードも外付けの配列になります（GNOME の配列はすべてのキーボードで共通のため）。
- 切り替えのたびとサービスの起動時（ログイン時など）に IBus が再起動するため、約1秒日本語入力が止まります。
- 切り替えの瞬間、入力ソースの表示が一瞬変わります。

## Development

### Project structure

```
bin/hotplug-layout             本体（bash）
systemd/hotplug-layout.service ユーザーサービスのユニットファイル
config/config.example          設定ファイルの例
tests/                         テストとテスト用のデバイス一覧
install.sh / uninstall.sh      インストーラとアンインストーラ
```

### Trying changes

本体を編集したら、インストーラを実行し直すと反映されます。設定ファイルと Mozc のバックアップは上書きされません。

```bash
./install.sh
```

サービスを止めて、本体を直接実行することもできます。ログがそのまま端末に出るので、デバッグに便利です。

```bash
systemctl --user stop hotplug-layout
KEYBOARD_RULES='Keychron K2=us' DEFAULT_LAYOUT=jp bin/hotplug-layout
```

終わったら Ctrl+C で止め、`systemctl --user start hotplug-layout` でサービスを再開します。

### Testing

[ShellCheck](https://github.com/koalaman/shellcheck) が必要です。

```bash
tests/test_decide_layout.sh
tests/test_apply_xkb_layout.sh
tests/test_apply_mozc_layout.sh
tests/test_detect_keyboard.sh
shellcheck -x bin/hotplug-layout install.sh uninstall.sh tests/*.sh
```

テストは実機のキーボードも GNOME も使いません。`test_decide_layout.sh` は `tests/fixtures/` の偽のデバイス一覧で、どの配列が選ばれるかを確かめます。`test_apply_xkb_layout.sh` は `gsettings` を偽物に差し替えて、入力ソースの書き換え方を確かめます。`test_apply_mozc_layout.sh` は `ibus` を偽物に差し替えて、起動時とホットプラグのときに IBus が再起動されるかを確かめます。`test_detect_keyboard.sh` は `install.sh` のキーボード検出を疑似端末（`script`、ja_JP.UTF-8 ロケールが必要）の中で動かし、待機中の表示と登録される値を確かめます。

新しいデバイス一覧で判定を手早く確かめたいときは、`INPUT_DEVICES` 環境変数で本体が読む一覧を差し替えられます。

```bash
INPUT_DEVICES=tests/fixtures/devices-with-us.txt KEYBOARD_RULES='Keychron K2=us' \
  bash -c 'source bin/hotplug-layout; decide_layout'
```

## Contributing

Issue や PR を歓迎します。

### Reporting bugs

次の情報があると、原因を調べやすくなります。

- `gnome-shell --version` と `apt policy ibus-mozc` の結果
- セッションの種類（`echo $XDG_SESSION_TYPE`）
- 入力ソースの一覧（`gsettings get org.gnome.desktop.input-sources sources`）
- 問題が起きたキーボードの名前（`grep Name= /proc/bus/input/devices` で確認）と接続方法（USB / Bluetooth）
- ログ（`journalctl --user -u hotplug-layout -n 50`）

### Pull requests

- 送る前に、[Testing](#testing) のテストと shellcheck が通ることを確認してください。
- 動作を変えた場合は、`tests/` にテストケースを追加してください。
- GNOME や IBus に関わる変更は、実機で接続・切断して確かめた内容を PR に書いてください。

## License

このプロジェクトは [MIT License](LICENSE) のもとで公開されています。
