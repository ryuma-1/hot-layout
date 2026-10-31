#!/usr/bin/env bash
# hotplug-layout のアンインストーラ
#
# 使い方:
#   ./uninstall.sh       対話形式でアンインストール
#   ./uninstall.sh -y    確認なしでアンインストール
#
# 行うこと:
#   1. サービスの停止と無効化、ユニットファイルの削除
#   2. 本体の削除
#   3. Mozc 設定ファイルをインストール前の状態に戻す（バックアップから）
#   4. GNOME の xkb 配列を、外付けキーボードが無いときの配列に戻す
#   5. 設定ファイルの削除
set -euo pipefail

NAME="hotplug-layout"

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
BIN_FILE="$HOME/.local/bin/$NAME"
CONFIG_DIR="$CONFIG_HOME/$NAME"
CONFIG_FILE="$CONFIG_DIR/config"
UNIT_FILE="$CONFIG_HOME/systemd/user/$NAME.service"
MOZC_CONFIG="$CONFIG_HOME/mozc/ibus_config.textproto"
MOZC_BACKUP="$CONFIG_DIR/ibus_config.textproto.orig"
SCHEMA="org.gnome.desktop.input-sources"

ASSUME_YES=0

info() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ask "質問" [既定値] -> 回答を標準出力に出す（-y のときは既定値）
ask() {
  local prompt="$1" default="${2:-}" answer
  if (( ASSUME_YES )); then
    printf '%s\n' "$default"
    return
  fi
  read -r -p "$prompt${default:+ [$default]}: " answer || answer=""
  printf '%s\n' "${answer:-$default}"
}

# confirm "質問" 既定値(y/n) -> y なら成功
confirm() {
  local hint="y/N"
  [[ "${2:-n}" == y ]] && hint="Y/n"
  [[ "$(ask "$1 ($hint)" "${2:-n}")" == [yY]* ]]
}

usage() {
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# 設定ファイルから値を読む（ファイルを実行せずに取り出す）
config_value() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  sed -nE "s/^$1=['\"]?([^'\"]*)['\"]?[[:space:]]*$/\1/p" "$CONFIG_FILE" | tail -n1
}

# ---- 各手順 ----

remove_service() {
  if [[ -f "$UNIT_FILE" ]]; then
    # 先に止めておかないと、Mozc の設定を戻した直後にサービスが書き換えてしまう
    systemctl --user disable --now "$NAME.service" >/dev/null 2>&1 || true
    rm -f "$UNIT_FILE"
    systemctl --user daemon-reload
    info "サービスを停止して削除しました"
  else
    info "ユニットファイルが無いので、サービスの削除は省略します"
  fi
}

remove_binary() {
  if [[ -f "$BIN_FILE" ]]; then
    rm -f "$BIN_FILE"
    info "削除しました: $BIN_FILE"
  fi
}

restore_mozc() {
  if [[ -f "$MOZC_BACKUP" ]]; then
    if confirm "Mozc の設定をインストール前の状態に戻しますか？" y; then
      install -m644 "$MOZC_BACKUP" "$MOZC_CONFIG"
      rm -f "$MOZC_BACKUP"
      info "Mozc の設定を戻しました: $MOZC_CONFIG"
      reload_ibus
    fi
  elif [[ -f "$MOZC_CONFIG" ]]; then
    warn "Mozc 設定のバックアップが見つかりません"
    if confirm "Mozc の配列設定（layout）を既定値の \"default\" に戻しますか？" y; then
      sed -i -E 's/^([[:space:]]*layout[[:space:]]*:[[:space:]]*)"[^"]*"/\1"default"/' "$MOZC_CONFIG"
      info "Mozc の配列設定を \"default\" に戻しました"
      reload_ibus
    fi
  fi
}

reload_ibus() {
  if ibus write-cache && ibus restart; then
    info "IBus を再起動しました"
  else
    warn "IBus の再起動に失敗しました。ログインし直すと反映されます"
  fi
}

restore_xkb() {
  local layout current new old target
  layout=$(config_value DEFAULT_LAYOUT)
  [[ -n "$layout" ]] || return 0

  current=$(gsettings get "$SCHEMA" sources)
  [[ "$current" == *"('xkb', "* ]] || return 0
  # 本体と同じく、最初の xkb エントリを差し替え、同じ配列が後ろにあれば入れ替える
  old=$(grep -oE "\('xkb', '[^']+'\)" <<<"$current" | head -n1)
  target="('xkb', '${layout}')"
  new=${current/"$target"/@@}
  new=${new/"$old"/"$target"}
  new=${new/@@/"$old"}
  [[ "$current" != "$new" ]] || return 0

  if confirm "GNOME の配列を「${layout}」に戻しますか？（いま: ${current}）" y; then
    gsettings set "$SCHEMA" sources "$new"
    info "GNOME の配列を戻しました: $new"
  fi
}

remove_config() {
  [[ -d "$CONFIG_DIR" ]] || return 0
  if [[ -f "$MOZC_BACKUP" ]]; then
    # Mozc の設定を戻さなかったときは、あとで戻せるようにバックアップだけ残す
    rm -f "$CONFIG_FILE"
    info "削除しました: $CONFIG_FILE"
    info "Mozc 設定のバックアップは残しました: $MOZC_BACKUP"
    return
  fi
  rm -rf "$CONFIG_DIR"
  info "削除しました: $CONFIG_DIR"
}

main() {
  while (( $# > 0 )); do
    case "$1" in
      -y|--yes) ASSUME_YES=1 ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "不明なオプション: $1" ;;
    esac
    shift
  done

  remove_service
  remove_binary
  restore_mozc
  restore_xkb
  remove_config

  cat >&2 <<EOF

アンインストールが完了しました。
  配列が切り替わっていなければ、Super+Space を2回押して入力ソースを選び直してください。
  GNOME 拡張「Input source D-Bus interface」は残っています。不要なら「拡張機能」アプリで無効にしてください。
EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
