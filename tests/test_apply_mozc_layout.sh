#!/usr/bin/env bash
# Mozc 配列の書き換え（update_mozc_config / apply_mozc_layout / sync_mozc_layout）と
# 起動時の判定（check_startup）のテスト
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
# 偽の配列判定: 常に us
decide_layout() { echo us; }

# expect "説明" 期待値 実際の値
expect() {
  if [[ "$3" == "$2" ]]; then
    printf 'ok    %s\n' "$1"
  else
    printf 'FAIL  %s（期待: %s, 実際: %s）\n' "$1" "$2" "$3"
    failed=1
  fi
}

# setup 今の配列（省略するとファイルを消す）
setup() {
  if [[ -n "${1:-}" ]]; then
    printf 'engines {\n  layout : "%s"\n  layout_variant : ""\n}\n' "$1" >"$MOZC_CONFIG"
  else
    rm -f "$MOZC_CONFIG"
  fi
  RESTARTS=0 REACTIVATED=0 CHANGED=0
}

file_layout() { grep -o 'layout : "[^"]*"' "$MOZC_CONFIG"; }

# update_mozc_config: ファイルだけを書き換える
setup jp; update_mozc_config us; status=$?
expect "配列が変われば書き換える"           'layout : "us"' "$(file_layout)"
expect "配列が変われば 0 を返す"            0 "$status"
expect "layout_variant は書き換えない"      1 "$(grep -c 'layout_variant : ""' "$MOZC_CONFIG")"
setup us; update_mozc_config us; status=$?
expect "同じ配列なら 1 を返す"              1 "$status"
setup; update_mozc_config us; status=$?
expect "ファイルがなければ 1 を返す"        1 "$status"
expect "update_mozc_config は IBus に触らない" 0 "$RESTARTS"

# apply_mozc_layout: ホットプラグ時。変化があったときだけ再起動
setup jp; apply_mozc_layout us
expect "配列が変われば IBus を再起動"       "1 1" "$RESTARTS $CHANGED"
setup us; apply_mozc_layout us
expect "同じ配列なら IBus を再起動しない"   "0 0" "$RESTARTS $CHANGED"

# sync_mozc_layout: 起動時。変化がなくても再起動
setup us; sync_mozc_layout us
expect "起動時は同じ配列でも IBus を再起動" "1 1" "$RESTARTS $CHANGED"
setup jp; sync_mozc_layout us
expect "起動時に配列が変われば書き換えて再起動" "1 layout : \"us\"" "$RESTARTS $(file_layout)"
setup; sync_mozc_layout us
expect "起動時でもファイルがなければ再起動しない" "0 0" "$RESTARTS $CHANGED"

# check_startup / check: Mozc が変われば入力ソースを選び直す
setup us; check_startup
expect "起動時の判定は選び直す"             "1 1" "$RESTARTS $REACTIVATED"
setup us; check
expect "ホットプラグの判定は何もしない"     "0 0" "$RESTARTS $REACTIVATED"
setup jp; check
expect "ホットプラグで配列が変われば選び直す" "1 1" "$RESTARTS $REACTIVATED"

if (( failed )); then
  echo "テストに失敗しました"
  exit 1
fi
echo "すべてのテストに成功しました"
