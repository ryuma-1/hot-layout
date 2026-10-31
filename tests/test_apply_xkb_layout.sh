#!/usr/bin/env bash
# GNOME 入力ソースの書き換え（apply_xkb_layout）のテスト
#   gsettings を偽物に差し替えて、書き込まれる値を確かめる
#   実行: tests/test_apply_xkb_layout.sh
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck source=bin/hotplug-layout
source bin/hotplug-layout

failed=0
SOURCES=""

# 偽の gsettings: get は SOURCES を返し、set は SOURCES に書き込む
gsettings() {
  case "$1" in
    get) printf '%s\n' "$SOURCES" ;;
    set) SOURCES="$4" ;;
  esac
}
log() { :; }

# check "説明" 書き換え前 配列 期待する書き換え後
check() {
  local desc="$1" expected="$4"
  SOURCES="$2"
  apply_xkb_layout "$3"
  if [[ "$SOURCES" == "$expected" ]]; then
    printf 'ok    %s\n' "$desc"
  else
    printf 'FAIL  %s（期待: %s, 実際: %s）\n' "$desc" "$expected" "$SOURCES"
    failed=1
  fi
}

check "xkb を差し替え"             "[('xkb', 'jp'), ('ibus', 'mozc-jp')]"               us "[('xkb', 'us'), ('ibus', 'mozc-jp')]"
check "同じ配列なら変えない"       "[('xkb', 'us'), ('ibus', 'mozc-jp')]"               us "[('xkb', 'us'), ('ibus', 'mozc-jp')]"
check "後ろにある同じ配列と入れ替え" "[('xkb', 'jp'), ('xkb', 'us'), ('ibus', 'mozc-jp')]" us "[('xkb', 'us'), ('xkb', 'jp'), ('ibus', 'mozc-jp')]"
check "入れ替えて元に戻る"         "[('xkb', 'us'), ('xkb', 'jp'), ('ibus', 'mozc-jp')]" jp "[('xkb', 'jp'), ('xkb', 'us'), ('ibus', 'mozc-jp')]"
check "xkb が無ければ先頭に追加"   "[('ibus', 'mozc-jp')]"                              us "[('xkb', 'us'), ('ibus', 'mozc-jp')]"
check "空なら xkb だけ"            "@a(ss) []"                                          us "[('xkb', 'us')]"

if (( failed )); then
  echo "テストに失敗しました"
  exit 1
fi
echo "すべてのテストに成功しました"
