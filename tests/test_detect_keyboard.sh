#!/usr/bin/env bash
# install.sh のキーボード検出（new_keyboards / detect_keyboard）のテスト
#   偽のデバイス一覧（tests/fixtures/）を使い、detect_keyboard は疑似端末（script）の中で動かす
#   実行: tests/test_detect_keyboard.sh
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck source=install.sh
source install.sh
set +e   # install.sh の set -e を外して、失敗しても最後まで確かめる

FIXTURES=tests/fixtures
failed=0
# uutils coreutils では、ja_JP.UTF-8 の sort の順（i8042 → PNP0C0C）を comm がバイト順でないと判断する（devices-laptop*.txt で起きる）
export LC_ALL=ja_JP.UTF-8

# expect "説明" 期待値 実際の値
expect() {
  if [[ "$3" == "$2" ]]; then
    printf 'ok    %s\n' "$1"
  else
    printf 'FAIL  %s（期待: %s, 実際: %s）\n' "$1" "$2" "$3"
    failed=1
  fi
}

# new_keyboards: 前の一覧に無かったキーボードだけを出す
baseline=$(INPUT_DEVICES="$FIXTURES/devices-laptop.txt" device_table)
err=$(INPUT_DEVICES="$FIXTURES/devices-laptop-with-us.txt" new_keyboards "$baseline" 2>&1 >/dev/null)
expect "new_keyboards は警告を出さない"        "" "$err"
expect "new_keyboards は増えたキーボードを出す" "Keychron K2" \
  "$(INPUT_DEVICES="$FIXTURES/devices-laptop-with-us.txt" new_keyboards "$baseline" 2>/dev/null)"

# run_detect 入力までの秒数 入力 [デバイスが増えるまでの秒数]
#   疑似端末の中で detect_keyboard を動かす。画面（標準エラー）を SCREEN、標準出力を OUT、終了コードを RC に入れる
run_detect() {
  local tmp devices
  tmp=$(mktemp -d)
  devices="$tmp/devices"
  cp "$FIXTURES/devices-laptop.txt" "$devices"
  if [[ -n "${3:-}" ]]; then
    (sleep "$3"; cp "$FIXTURES/devices-laptop-with-us.txt" "$devices") &
  fi
  cat >"$tmp/run.sh" <<EOS
source ./install.sh
DETECT_TIMEOUT=2 INPUT_DEVICES='$devices'
detect_keyboard >'$tmp/out'
EOS
  SCREEN=$( (sleep "$1"; printf '%b' "$2"; sleep 1) | script -qec "bash '$tmp/run.sh'" /dev/null)
  RC=$?
  OUT=$(cat "$tmp/out")
  wait
  rm -rf "$tmp"
}

# 画面の行数（改行の数）
screen_lines() { printf '%s' "$SCREEN" | tr -cd '\n' | wc -c; }
# 残り秒数を含む行の数（上書きされていれば 1）
countdown_lines() { printf '%s\n' "$SCREEN" | grep -c '残り'; }
# comm の警告の行数
comm_lines() { printf '%s\n' "$SCREEN" | grep -c 'comm:'; }

# 自動検出: 接続を検出して、既定値のまま登録する
run_detect 4 '\n\n' 1
expect "検出: 終了コード 0"                  0 "$RC"
expect "検出: 標準出力は パターン=配列 だけ" "Keychron K2=us" "$OUT"
expect "検出: comm の警告が出ない"           0 "$(comm_lines)"
expect "検出: 残り秒数は1行で上書き"         1 "$(countdown_lines)"
expect "検出: 画面は20行以内"               1 "$(( $(screen_lines) <= 20 ))"

# 時間切れ: 一覧に切り替わり、番号で選ぶ
run_detect 4 '1\n\n\n'
expect "時間切れ: 終了コード 0"              0 "$RC"
expect "時間切れ: 一覧から選べる"            "AT Translated Set 2 keyboard=us" "$OUT"
expect "時間切れ: comm の警告が出ない"       0 "$(comm_lines)"
expect "時間切れ: 残り秒数は1行で上書き"     1 "$(countdown_lines)"

# 標準エラーが端末でないとき（ログに取るときなど）は、上書き用の制御文字を出さない
log=$(DETECT_TIMEOUT=1 INPUT_DEVICES="$FIXTURES/devices-laptop.txt" detect_keyboard </dev/null 2>&1 >/dev/null)
expect "端末でない: 行頭復帰や行消去を出さない" 0 "$(printf '%s' "$log" | grep -c $'\r\\|\e\\[K')"

if (( failed )); then
  echo "テストに失敗しました"
  exit 1
fi
echo "すべてのテストに成功しました"
