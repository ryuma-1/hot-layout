#!/usr/bin/env bash
# Mozc 配列の書き換え（apply_mozc_layout）と起動時の check のテスト
#   ibus を偽物に差し替えて、再起動されたかを確かめる
#   実行: tests/test_apply_mozc_layout.sh
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck source=bin/hotplug-layout
source bin/hotplug-layout

failed=0
MOZC_CONFIG=$(mktemp)
trap 'rm -f "$MOZC_CONFIG"' EXIT
RESTARTS=0
REACTIVATED=0

# 偽の ibus: restart の回数だけ数える
ibus() { [[ "$1" == restart ]] && RESTARTS=$((RESTARTS + 1)); return 0; }
wait_ibus() { :; }
reactivate() { REACTIVATED=1; }
apply_xkb_layout() { :; }
log() { :; }

# expect "説明" 期待値 実際の値
expect() {
  if [[ "$3" == "$2" ]]; then
    printf 'ok    %s\n' "$1"
  else
    printf 'FAIL  %s（期待: %s, 実際: %s）\n' "$1" "$2" "$3"
    failed=1
  fi
}

# setup 今の配列
setup() {
  printf 'engines {\n  layout : "%s"\n  layout_variant : ""\n}\n' "$1" >"$MOZC_CONFIG"
  RESTARTS=0 REACTIVATED=0 CHANGED=0
}

setup jp; apply_mozc_layout us
expect "配列が変われば書き換える"         'layout : "us"' "$(grep -o 'layout : "[^"]*"' "$MOZC_CONFIG")"
expect "配列が変われば IBus を再起動"     1 "$RESTARTS"

setup us; apply_mozc_layout us
expect "同じ配列なら IBus を再起動しない" 0 "$RESTARTS"
expect "同じ配列なら CHANGED のまま"      0 "$CHANGED"

setup us; apply_mozc_layout us startup
expect "起動時は同じ配列でも IBus を再起動" 1 "$RESTARTS"
expect "起動時は同じ配列でも CHANGED"     1 "$CHANGED"

decide_layout() { echo us; }
setup us; check startup
expect "起動時の check は選び直す"        1 "$REACTIVATED"
setup us; check
expect "ホットプラグの check は何もしない" "0 0" "$RESTARTS $REACTIVATED"

if (( failed )); then
  echo "テストに失敗しました"
  exit 1
fi
echo "すべてのテストに成功しました"
