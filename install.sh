#!/usr/bin/env bash
# hotplug-layout のインストーラ
#
# 使い方:
#   ./install.sh       対話形式でインストール（外付けキーボードを検出して設定ファイルを作る）
#   ./install.sh -y    確認なしでインストール（設定ファイルは例をコピーするだけ）
#
# 行うこと:
#   1. 必要なコマンドと GNOME 拡張の確認
#   2. 本体とユニットファイルの配置
#   3. Mozc 設定ファイルのバックアップ（uninstall.sh で元に戻すため）
#   4. 設定ファイルの作成（すでにあれば変更しない）
#   5. systemd ユーザーサービスの有効化と起動
set -euo pipefail

NAME="hotplug-layout"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$CONFIG_HOME/$NAME"
CONFIG_FILE="$CONFIG_DIR/config"
UNIT_DIR="$CONFIG_HOME/systemd/user"
MOZC_CONFIG="$CONFIG_HOME/mozc/ibus_config.textproto"
MOZC_BACKUP="$CONFIG_DIR/ibus_config.textproto.orig"
INPUT_DEVICES="${INPUT_DEVICES:-/proc/bus/input/devices}"
IS_PATH="/raiden_fumo/InputSources"
DETECT_TIMEOUT=60   # キーボードの自動検出を待つ秒数

ASSUME_YES=0

# ---- 表示（標準出力は値の受け渡しに使うので、メッセージはすべて標準エラーへ） ----

info() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
item() { printf '    %s\n' "$*" >&2; }   # 一覧の1項目（==> の後ろの文字に揃える）

# ask "質問" [既定値] -> 回答を標準出力に出す（-y のときは既定値）
ask() {
  local prompt="$1" default="${2:-}" answer
  if (( ASSUME_YES )); then
    printf '%s\n' "$default"
    return
  fi
  read -r -p $'\033[1;32m ? \033[0m '"$prompt${default:+ [$default]}: " answer || answer=""
  printf '%s\n' "${answer:-$default}"
}

# confirm "質問" -> y なら成功
confirm() {
  [[ "$(ask "$1 (y/N)")" == [yY]* ]]   # 空欄は N
}

usage() {
  sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---- 事前チェック ----

check_repo_files() {
  local f
  for f in "bin/$NAME" "systemd/$NAME.service" "config/config.example"; do
    [[ -f "$REPO_DIR/$f" ]] || die "リポジトリ内に $f がありません。リポジトリのルートで実行してください"
  done
}

check_commands() {
  local cmd missing=()
  for cmd in systemctl gsettings gdbus ibus udevadm grep sed install comm; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if (( ${#missing[@]} > 0 )); then
    die "必要なコマンドが見つかりません: ${missing[*]}"
  fi
}

check_session() {
  [[ "${XDG_CURRENT_DESKTOP:-}" == *GNOME* ]] \
    || warn "GNOME 以外のデスクトップでは動作しません（XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-未設定}）"
  [[ "${XDG_SESSION_TYPE:-}" == wayland ]] \
    || warn "動作確認は Wayland セッションのみです（XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-未設定}）"
}

check_extension() {
  local out
  if out=$(gdbus introspect --session --dest org.gnome.Shell --object-path "$IS_PATH" 2>/dev/null) \
     && [[ "$out" == *"Set("* ]]; then
    info "GNOME 拡張「Input source D-Bus interface」を確認しました"
    return
  fi
  warn "GNOME 拡張「Input source D-Bus interface」が見つかりません"
  warn "  extensions.gnome.org からインストールして有効にしてください"
  warn "  拡張が無いと、切り替え後に Super+Space で入力ソースを選び直す必要があります"
  if (( ! ASSUME_YES )) && ! confirm "このままインストールを続けますか？"; then
    die "中止しました"
  fi
}

# ---- 配置 ----

install_files() {
  install -Dm755 "$REPO_DIR/bin/$NAME" "$BIN_DIR/$NAME"
  install -Dm644 "$REPO_DIR/systemd/$NAME.service" "$UNIT_DIR/$NAME.service"
  info "配置しました: $BIN_DIR/$NAME"
  info "配置しました: $UNIT_DIR/$NAME.service"

  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR が PATH に入っていません（サービスの動作には影響しません）" ;;
  esac
}

backup_mozc() {
  if [[ ! -f "$MOZC_CONFIG" ]]; then
    warn "Mozc の設定ファイルが見つかりません: $MOZC_CONFIG"
    warn "  Mozc を一度使うと作成されます。作成後にサービスを再起動してください"
    return
  fi
  if [[ -f "$MOZC_BACKUP" ]]; then
    # 再インストール時に、書き換え済みの設定でバックアップを上書きしないようにする
    info "Mozc 設定のバックアップは既にあるので残します: $MOZC_BACKUP"
    return
  fi
  install -Dm644 "$MOZC_CONFIG" "$MOZC_BACKUP"
  info "Mozc 設定をバックアップしました: $MOZC_BACKUP"
}

# ---- キーボードの検出 ----

# /proc/bus/input/devices を「Sysfs<TAB>EV<TAB>名前」の1行1デバイスに変換して並べる
#   Sysfs はデバイスごとに固有なので、同じ名前のデバイスがあっても区別できる
#   comm で比べるので、sort と comm の並び順を C ロケールで揃える（ja_JP.UTF-8 では食い違う）
device_table() {
  local line name="" sysfs="" ev=""
  while IFS= read -r line || [[ -n "$name" ]]; do
    case "$line" in
      'N: Name='*) name="${line#N: Name=\"}"; name="${name%\"}" ;;
      'S: Sysfs='*) sysfs="${line#S: Sysfs=}" ;;
      'B: EV='*) ev="${line#B: EV=}" ;;
      '')
        [[ -n "$name" ]] && printf '%s\t%s\t%s\n' "$sysfs" "$ev" "$name"
        name="" sysfs="" ev=""
        ;;
    esac
  done <"$INPUT_DEVICES" | LC_ALL=C sort
}

# device_table 形式の行のうち、キーボードらしいものの名前だけを重複なしで出す
#   キーリピート（EV_REP, 0x100000）を持つものをキーボードとみなす
#   電源ボタンやマウス、"System Control" など、文字を打たないデバイスはこれで除ける
filter_keyboards() {
  local sysfs ev name
  while IFS=$'\t' read -r sysfs ev name; do
    [[ "$ev" =~ ^[0-9a-fA-F]+$ ]] || continue
    if (( 16#$ev & 0x100000 )); then
      printf '%s\n' "$name"
    fi
  done | sort -u
}

# 接続中のキーボードの名前を並べる
keyboard_names() {
  device_table | filter_keyboards
}

# baseline に無かったキーボードの名前を出す
new_keyboards() {
  LC_ALL=C comm -13 <(printf '%s\n' "$1") <(device_table) | filter_keyboards
}

# 接続中のキーボードを番号付きで表示し、選ばれた名前を標準出力に出す
choose_keyboard() {
  local names=() name choice i
  while IFS= read -r name; do
    [[ -n "$name" ]] && names+=("$name")
  done < <(keyboard_names)
  if (( ${#names[@]} == 0 )); then
    warn "キーボードが見つかりませんでした"
    return 1
  fi

  info "接続中のキーボード:"
  for i in "${!names[@]}"; do
    item "$((i + 1))) ${names[$i]}"
  done
  choice=$(ask "登録するキーボードの番号（Enter でスキップ）")
  [[ -n "$choice" ]] || return 1
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#names[@]} )); then
    warn "番号が正しくありません: $choice"
    return 1
  fi
  printf '%s\n' "${names[$((choice - 1))]}"
}

# 複数行の共通の先頭部分を返す
#   "Keychron K2" / "Keychron K2 System Control" -> "Keychron K2"
common_prefix() {
  local prefix line
  IFS= read -r prefix || return 0
  while IFS= read -r line; do
    while [[ -n "$prefix" && "$line" != "$prefix"* ]]; do
      prefix="${prefix%?}"
    done
  done
  sed -E 's/[[:space:]_-]+$//' <<<"$prefix"
}

# デバイス名を正規表現として安全な形にする
#   正規表現の記号はエスケープし、ルールの区切り（;）とクォート（'）は任意の1文字（.）に置き換える
regex_escape() {
  # [. は文字クラス内で照合要素の開始と解釈されるので、[ はクラスの最後に置く
  sed -E -e 's/[].*^$+?(){}|\[]/\\&/g' -e "s/[;']/./g" <<<"$1"
}

# 端末に溜まったキー入力を捨てる（待っている間に打たれた文字が次の質問に混ざらないように）
discard_input() {
  [[ -t 0 ]] || return 0
  while read -rsn1 -t 0.1 _; do :; done
}

# 待機中の残り秒数を、同じ行に上書きして表示する（標準エラーが端末のときだけ）
#   show_wait 経過（0.5 秒単位） / clear_wait で行を消す
show_wait() {
  [[ -t 2 ]] || return 0
  local total=$((DETECT_TIMEOUT * 2)) width=20 filled bar
  filled=$(( $1 * width / total ))
  printf -v bar '%*s' "$filled" ''
  bar="${bar// /#}"
  printf -v bar '%-*s' "$width" "$bar"
  printf '\r\033[K    待機中 [%s] 残り %d 秒で一覧に切り替え' "${bar// /-}" $(( (total - $1 + 1) / 2 )) >&2
}
clear_wait() { [[ -t 2 ]] && printf '\r\033[K' >&2; return 0; }

# 外付けキーボードを1台検出し、「パターン=配列」の形で標準出力に出す
detect_keyboard() {
  local baseline new="" suggestion="" pattern layout line rc key elapsed=0 pressed=0
  baseline=$(device_table)

  info "登録するキーボードを接続してください（接続済みなら、抜き挿しするか Bluetooth をオフ・オン）"
  info "自動で検出します。一覧から選ぶときは Enter"

  # 0.5 秒ごとに確認する。read -t を待ち時間に兼用し、Enter が押されたら一覧に切り替える
  #   1文字ずつ読むので、Enter 以外のキーは表示せずに捨てる（次の質問の回答に混ざらない）
  while (( elapsed < DETECT_TIMEOUT * 2 )); do
    new=$(new_keyboards "$baseline")
    [[ -n "$new" ]] && break
    if (( ASSUME_YES )); then
      break
    fi
    show_wait "$elapsed"
    rc=0 key=""
    read -rsn1 -t 0.5 key || rc=$?
    if (( rc == 0 )); then
      [[ -z "$key" ]] && { pressed=1; break; }   # Enter が押された
      continue                   # ほかのキーは無視（経過時間にも数えない）
    elif (( rc <= 128 )); then
      sleep 0.5                  # 入力が端末でない（EOF）ときは普通に待つ
    fi
    elapsed=$((elapsed + 1))
  done
  clear_wait

  if [[ -n "$new" ]]; then
    # 接続直後はデバイスが順番に現れるので、少し待ってから全部拾う
    sleep 1
    discard_input
    new=$(new_keyboards "$baseline")
    info "見つかりました:"
    while IFS= read -r line; do item "$line"; done <<<"$new"
    suggestion=$(common_prefix <<<"$new")
    [[ -n "$suggestion" ]] || suggestion=$(head -n1 <<<"$new")
  else
    (( pressed )) || warn "${DETECT_TIMEOUT} 秒待っても見つからないので、接続中のキーボードから選んでください"
    suggestion=$(choose_keyboard) || return 1
  fi

  pattern=$(ask "ルールに使う名前（これを含む名前のデバイスが対象。Enter でそのまま）" "$suggestion")
  [[ -n "$pattern" ]] || { warn "名前が空なので登録しません"; return 1; }

  layout=$(ask "このキーボードの配列 (us / jp)" us)
  [[ "$layout" =~ ^[a-z][a-z0-9_]*$ ]] || { warn "配列名が不正です: $layout"; return 1; }

  printf '%s=%s\n' "$(regex_escape "$pattern")" "$layout"
}

# ---- 設定ファイル ----

setup_config() {
  local rules=() rule default_layout joined

  if [[ -f "$CONFIG_FILE" ]]; then
    info "設定ファイルは既にあるので変更しません: $CONFIG_FILE"
    return
  fi
  install -d "$CONFIG_DIR"

  if (( ! ASSUME_YES )); then
    info "外付けキーボードを登録します"
    while :; do
      if rule=$(detect_keyboard); then
        rules+=("$rule")
        info "登録しました: $rule"
      fi
      confirm "ほかのキーボードも登録しますか？" || break
    done
  fi

  if (( ${#rules[@]} == 0 )); then
    install -m644 "$REPO_DIR/config/config.example" "$CONFIG_FILE"
    warn "設定ファイルの例をコピーしました。キーボード名を編集してください: $CONFIG_FILE"
    return
  fi

  default_layout=$(ask "外付けキーボードが無いときの配列 (us / jp)" jp)
  joined=$(IFS=';'; printf '%s' "${rules[*]}")
  {
    echo "# hotplug-layout の設定（install.sh が作成）"
    echo "# 書き方はリポジトリの config/config.example を参照"
    echo "# 変更したら反映: systemctl --user restart $NAME"
    printf "KEYBOARD_RULES='%s'\n" "$joined"
    printf "DEFAULT_LAYOUT='%s'\n" "$default_layout"
  } >"$CONFIG_FILE"
  info "設定ファイルを作成しました: $CONFIG_FILE"
}

# ---- サービス ----

enable_service() {
  systemctl --user daemon-reload
  systemctl --user enable "$NAME.service" >/dev/null 2>&1
  systemctl --user restart "$NAME.service"
  sleep 1
  if systemctl --user is-active --quiet "$NAME.service"; then
    info "サービスを起動しました"
  else
    warn "サービスが起動していません。ログを確認してください:"
    warn "  journalctl --user -u $NAME -n 30"
  fi
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

  check_repo_files
  check_commands
  check_session
  check_extension
  install_files
  backup_mozc
  setup_config
  enable_service

  cat >&2 <<EOF

インストールが完了しました。
  ログを見る:     journalctl --user -u $NAME -f
  設定を変える:   $CONFIG_FILE を編集して systemctl --user restart $NAME
  アンインストール: ./uninstall.sh
EOF
}

# テストから source したときは main を動かさない
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
